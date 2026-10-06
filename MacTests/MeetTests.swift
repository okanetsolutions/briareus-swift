// Meet.swift and MeetTools.swift (tests/core_meet_tests.c): the meeting assistant's ElevenLabs agent and its events, its
// project tools, its transcript and the costs.
import XCTest
@testable import BriareusMacCore

final class MeetTests: XCTestCase {
    private func persona(_ independent: Bool) -> MeetPersona {
        MeetPersona(name: "Nadin", wakeWords: "Nadin, assistant", project: "Briareus (nadinyamaui/briareus)", voice: "zozOsuFj6BSfLStTxdrK",
                    introduce: true, independent: independent)
    }
    private func json(_ text: String) -> JSON { JSON.parse(text)! }
    private func near(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-9 }

    func testTheAgentSpeaksInTheUsersVoiceWithTheProjectTools() {
        var p = persona(false)
        var body = Meet.agentBody(p, toolIDs: ["tool_1", "tool_2"])
        XCTAssertEqual(body["name"].string, "Briareus meeting assistant")
        let config = body["conversation_config"], tts = config["tts"], agent = config["agent"], prompt = agent["prompt"]
        XCTAssertEqual(tts["voice_id"].string, "zozOsuFj6BSfLStTxdrK")
        XCTAssertEqual(tts["model_id"].string, "eleven_v4_turbo")
        XCTAssertEqual(tts["agent_output_audio_format"].string, "pcm_24000")
        XCTAssertEqual(config["asr"]["user_input_audio_format"].string, "pcm_24000")
        XCTAssertEqual(config["conversation"]["max_duration_seconds"].int, 7200)
        XCTAssertEqual(agent["language"].string, "en")
        XCTAssertTrue(agent["first_message"].string!.contains("Nadin's AI assistant"))
        XCTAssertEqual(prompt["llm"].string, Meet.agentLLM)
        XCTAssertEqual(prompt["tool_ids"].count, 2)
        XCTAssertEqual(prompt["tool_ids"][1].string, "tool_2")
        XCTAssertEqual(prompt["built_in_tools"]["skip_turn"]["params"]["system_tool_type"].string, "skip_turn")
        let instructions = prompt["prompt"].string!
        XCTAssertTrue(instructions.contains("Speak as Nadin, in the first person"))
        XCTAssertTrue(instructions.contains("Nadin, assistant"))
        XCTAssertTrue(instructions.contains("call skip_turn"))
        XCTAssertTrue(instructions.contains("Briareus (nadinyamaui/briareus)"))
        XCTAssertTrue(instructions.contains("no tool changes anything"))
        p = persona(true)
        p.introduce = false
        body = Meet.agentBody(p, toolIDs: [])
        let quiet = body["conversation_config"]["agent"]
        XCTAssertEqual(quiet["first_message"].string, "")
        XCTAssertTrue(quiet["prompt"]["prompt"].string!.contains("Act independently on Nadin's behalf"))
        XCTAssertEqual(Meet.agentWSPath("agent_01abc"), "/v1/convai/conversation?agent_id=agent_01abc")
        XCTAssertEqual(Meet.agentWSPath("a&b=c"), "/v1/convai/conversation?agent_id=abc")
        XCTAssertEqual(Meet.signedWSPath(json(#"{"signed_url":"wss://api.elevenlabs.io/v1/convai/conversation?agent_id=a1&conversation_signature=s"}"#)),
                       "/v1/convai/conversation?agent_id=a1&conversation_signature=s")
        XCTAssertNil(Meet.signedWSPath(json(#"{"signed_url":"wss://evil.example/x"}"#)))
        XCTAssertEqual(Meet.createdID(json(#"{"agent_id":"agent_9"}"#)), "agent_9")
        XCTAssertEqual(Meet.createdID(json(#"{"id":"tool_9","tool_config":{}}"#)), "tool_9")
        XCTAssertNil(Meet.createdID(.null))
    }

    func testAPromptTheUserWroteReplacesTheDefaultWithItsPlaceholdersFilled() {
        var p = persona(false)
        let made = Meet.defaultPrompt(independent: false)
        XCTAssertTrue(made.contains("You speak for {name}") && made.contains("{wake_words}") && made.contains("{project}"))
        XCTAssertTrue(made.contains("list_conversations"))
        var filled = p
        filled.prompt = made
        XCTAssertEqual(Meet.instructions(filled), Meet.instructions(p))
        p.prompt = "Be {name} on {project}; answer to {wake_words}."
        p.firstMessage = "Hello, {name} here."
        let agent = Meet.agentBody(p, toolIDs: [])["conversation_config"]["agent"]
        XCTAssertEqual(agent["prompt"]["prompt"].string, "Be Nadin on Briareus (nadinyamaui/briareus); answer to Nadin, assistant.")
        XCTAssertEqual(agent["first_message"].string, "Hello, Nadin here.")
        // A first message written empty joins silently, whatever introduce says.
        p.firstMessage = ""
        XCTAssertEqual(Meet.firstMessage(p), "")
        XCTAssertEqual(Meet.defaultFirstMessage(introduce: false), "")
        XCTAssertTrue(Meet.defaultFirstMessage(introduce: true).contains("{name}'s AI assistant"))
    }

    func testToolsAreClientToolsThatWaitForTheApp() {
        var config = MeetTool.readPullRequest.body["tool_config"]
        XCTAssertEqual(config["type"].string, "client")
        XCTAssertEqual(config["name"].string, "read_pull_request")
        XCTAssertTrue(config["expects_response"].is(true))
        XCTAssertEqual(config["parameters"]["properties"]["number"]["type"].string, "integer")
        XCTAssertEqual(config["parameters"]["required"][0].string, "number")
        config = MeetTool.listConversations.body["tool_config"]
        XCTAssertEqual(config["parameters"]["required"].count, 0)
        for tool in MeetTool.allCases {
            // Read-only: nothing that starts, messages, merges, closes or deletes.
            for word in ["start", "send", "merge", "delete", "close"] { XCTAssertFalse(tool.name.contains(word)) }
        }
    }

    func testAudioPongsAndToolResultsGoOutAsTheAgentNamesThem() {
        XCTAssertEqual(Meet.audioEvent([1, -1]), #"{"user_audio_chunk":"AQD//w=="}"#)
        XCTAssertEqual(Meet.audioEvent([]), #"{"user_audio_chunk":""}"#)
        XCTAssertEqual(Meet.pongEvent(7), #"{"type":"pong","event_id":7}"#)
        XCTAssertEqual(Meet.startEvent, #"{"type":"conversation_initiation_client_data"}"#)
        let e = json(Meet.toolResultEvent(callID: "call_9", result: #"{"total":0}"#, isError: false))
        XCTAssertEqual(e["type"].string, "client_tool_result")
        XCTAssertEqual(e["tool_call_id"].string, "call_9")
        XCTAssertEqual(e["result"].string, #"{"total":0}"#)
        XCTAssertTrue(e["is_error"].is(false))
        XCTAssertEqual(json(Meet.answerNowEvent)["type"].string, "user_message")
    }

    func testAgentEventsAreRead() {
        XCTAssertEqual(MeetEvent(#"{"type":"conversation_initiation_metadata","conversation_initiation_metadata_event":{"conversation_id":"c","agent_output_audio_format":"pcm_24000","user_input_audio_format":"pcm_24000"}}"#), .ready)
        XCTAssertEqual(MeetEvent(#"{"type":"audio","audio_event":{"audio_base_64":"AQD//w==","event_id":3}}"#), .audio(Data([1, 0, 0xFF, 0xFF])))
        XCTAssertEqual(MeetEvent(#"{"type":"interruption","interruption_event":{"event_id":4}}"#), .interrupted)
        XCTAssertEqual(MeetEvent(#"{"type":"user_transcript","user_transcription_event":{"user_transcript":"Nadin, any news?","event_id":5}}"#), .heardTurn("Nadin, any news?"))
        XCTAssertEqual(MeetEvent(#"{"type":"agent_response","agent_response_event":{"agent_response":"CI is green.","event_id":6,"response_id":"r"}}"#), .said("CI is green."))
        XCTAssertEqual(MeetEvent(#"{"type":"ping","ping_event":{"event_id":8,"ping_ms":40}}"#), .ping(8))
        guard case .tool(let id, let name, let parameters)? = MeetEvent(#"{"type":"client_tool_call","client_tool_call":{"tool_name":"read_pull_request","tool_call_id":"call_1","parameters":{"number":12},"event_id":9,"expects_response":true}}"#) else {
            return XCTFail("not a tool call")
        }
        XCTAssertEqual(id, "call_1"); XCTAssertEqual(name, "read_pull_request"); XCTAssertEqual(parameters.serialized(), #"{"number":12}"#)
        XCTAssertEqual(MeetEvent(#"{"type":"client_error","error_event":{"code":1008,"error_name":"auth","message":"Bad key"}}"#), .error("ElevenLabs: Bad key"))
        XCTAssertEqual(MeetEvent(#"{"type":"vad_score","vad_score_event":{"vad_score":0.4}}"#), .other)
        XCTAssertNil(MeetEvent("not json"))
    }

    func testCostsFollowEachModelsRates() {
        XCTAssertTrue(near(MeetUsage(seconds: 90).cost(.agent), 0.12))
        XCTAssertTrue(near(MeetUsage(seconds: 90).cost(.live), 0.075))
        let rt = MeetUsage(textIn: 1e6, textCached: 1e6, textOut: 1e6, audioIn: 1e6, audioCached: 1e6, audioOut: 1e6, transcribedSeconds: 60, spokenChars: 1000)
        XCTAssertTrue(near(rt.cost(.realtime), 0.6 + 0.06 + 2.4 + 10 + 0.3 + 20 + 0.0045 + 0.04))
    }

    func testRecordsRoundTripAndAddUpByModel() {
        let a = MeetRecord(model: .live, started: 1000, seconds: 600, usage: MeetUsage(seconds: 600), agentCost: 0.4, requests: 3, answers: 2, answerSeconds: 30)
        let b = MeetRecord(model: .realtime, started: 2000, seconds: 300, usage: MeetUsage(audioOut: 1e5), agentCost: 0.1, requests: 1, answers: 1, answerSeconds: 8)
        let records = [a.json, b.json, a.json, json(#"{"model":"gpt-unknown"}"#)]
        let back = MeetRecord(records[1])!
        XCTAssertEqual(back.model, .realtime); XCTAssertTrue(near(back.usage.audioOut, 1e5)); XCTAssertTrue(near(back.started, 2000)); XCTAssertEqual(back.answers, 1)
        XCTAssertTrue(near(records[0]["voiceCost"].number ?? 0, 0.5))
        let t = MeetTotals.of(records)
        XCTAssertEqual(t[.live]!.meetings, 2); XCTAssertTrue(near(t[.live]!.seconds, 1200)); XCTAssertTrue(near(t[.live]!.voiceCost, 1.0))
        XCTAssertTrue(near(t[.live]!.agentCost, 0.8)); XCTAssertEqual(t[.live]!.requests, 6); XCTAssertTrue(near(t[.live]!.answerSeconds, 60))
        XCTAssertEqual(t[.realtime]!.meetings, 1); XCTAssertTrue(near(t[.realtime]!.voiceCost, 2.0))
        XCTAssertEqual(t[.agent]!.meetings, 0)
    }

    func testTheLogKeepsSpeakersOnTheirOwnLinesAndItsTail() {
        var log = MeetLog()
        XCTAssertEqual(log.tail(100), "")
        log.add(.meeting, " What is")
        log.add(.meeting, " the status?")
        log.add(.assistant, "Let me check.")
        log.add(.assistant, nil)
        XCTAssertEqual(log.tail(1000), "Meeting: What is the status?\nAssistant: Let me check.")
        XCTAssertEqual(log.tail(30), "Assistant: Let me check.")
        log.line(.lookup, "list_pull_requests")
        log.line(.lookup, "list_issues")
        log.line(.assistant, "Two are\nready.")
        log.line(.assistant, "One waits.")
        XCTAssertEqual(log.tail(1000), "Meeting: What is the status?\nAssistant: Let me check.\nLookup: list_pull_requests\n"
                                       + "Lookup: list_issues\nAssistant: Two are ready.\nAssistant: One waits.")
        let lines = MeetLog.lines(log.text)
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines[2].speaker, .lookup); XCTAssertEqual(lines[2].text, "list_pull_requests")
        log = MeetLog()
        for _ in 0..<2000 { log.add(.meeting, "and so on and so forth"); log.add(.assistant, "ok") }
        XCTAssertLessThanOrEqual(log.text.utf8.count, 24000 + 40)
        XCTAssertTrue(log.text.hasPrefix("Meeting: ") || log.text.hasPrefix("Assistant: "))
    }

    func testRepliesAreMadeFitToSay() {
        XCTAssertEqual(Meet.spoken("# Status\n\n- **CI** is `green`\n- PR #12 merged\n```\ncode\n```\n> done", 1000), "Status CI is green PR #12 merged done")
        XCTAssertEqual(Meet.spoken("One. Two. Three is long", 12), "One. Two.")
        XCTAssertEqual(Meet.spoken("abcdef ghijkl", 9), "abcdef")
        XCTAssertEqual(Meet.spoken("abcdefghijkl", 5), "abcde")
        XCTAssertEqual(Meet.spoken(nil, 5), "")
    }

    func testModelsAreNamed() {
        XCTAssertEqual(MeetModel.live.label, "GPT-Live 1")
        XCTAssertEqual(MeetModel.agent.label, "ElevenLabs agent")
        XCTAssertEqual(MeetModel.agent.id, "elevenlabs-agent")
        let i = Meet.instructions(MeetPersona())
        XCTAssertTrue(i.contains("You speak for the user") && i.contains("the project this project"))
    }

    // MARK: - Tools

    private let repo = "okanet/app"
    private let sessions = #"{"sessions":["#
        + #"{"id":"s1","repo":"okanet/app","title":"Fix the login","status":"idle","prStatus":{"number":12,"state":"merged","title":"Fix login","checks":{"total":3,"passed":3,"failed":0,"pending":0}}},"#
        + #"{"id":"s2","repo":"okanet/app","title":"Issue #7: Dark mode","status":"running"},"#
        + #"{"id":"s3","repo":"okanet/other","title":"Elsewhere","status":"idle"},"#
        + #"{"id":"s4","repo":"okanet/app","title":"Old","status":"closed","startedOnPr":20}]}"#

    private func run(_ tool: MeetTool, _ args: String, _ answers: [String?]) -> JSON {
        json(tool.summary(json(args), repo: repo, answers: answers.map { $0.map(json) }))
    }

    func testEachToolReadsTheProjectOnly() {
        XCTAssertEqual(MeetTool(rawValue: "list_issues"), .listIssues)
        XCTAssertNil(MeetTool(rawValue: "merge_pull_request"))
        var plan = MeetTool.readPullRequest.calls(json(#"{"number":12}"#), repo: repo)
        XCTAssertEqual(plan.calls.count, 2); XCTAssertNil(plan.refusal)
        XCTAssertEqual(plan.calls[0].op, "pull_files"); XCTAssertEqual(plan.calls[0].args["repo"].string, repo); XCTAssertEqual(plan.calls[0].args["pr"].int, 12)
        XCTAssertEqual(plan.calls[1].op, "pull_description")
        plan = MeetTool.readIssue.calls(json(#"{"issue":7}"#), repo: repo)
        XCTAssertEqual(plan.calls.map(\.op), ["issue", "issue_timeline", "sessions"])
        XCTAssertEqual(plan.calls[1].args["page"].int, 1)
        plan = MeetTool.readConversation.calls(json(#"{"session_id":"s1"}"#), repo: repo)
        XCTAssertEqual(plan.calls.map(\.op), ["sessions", "session"]); XCTAssertEqual(plan.calls[1].args["sessionId"].string, "s1")
        // Missing arguments are refused with what to say.
        plan = MeetTool.listFindings.calls([:], repo: repo)
        XCTAssertEqual(plan.calls.count, 0)
        XCTAssertTrue(plan.refusal?.contains("pull request") == true)
        XCTAssertEqual(MeetTool.readConversation.calls([:], repo: repo).calls.count, 0)
        let instructions = MeetTool.instructions(project: "App (okanet/app)")
        XCTAssertTrue(instructions.contains("App (okanet/app)") && instructions.contains("ready_to_merge"))
    }

    func testConversationsAreListedWithTheirPullRequests() {
        var o = run(.listConversations, "{}", [sessions])
        let list = o["conversations"]
        XCTAssertEqual(o["total"].int, 3)
        XCTAssertEqual(list[0]["session_id"].string, "s1")
        let pr = list[0]["pull_request"]
        XCTAssertEqual(pr["number"].int, 12)
        XCTAssertEqual(pr["state"].string, "merged")
        XCTAssertEqual(pr["checks"].string, "all 3 passed")
        XCTAssertEqual(list[2]["pull_request"]["number"].int, 20)
        o = run(.listConversations, #"{"active_only":true}"#, [sessions])
        XCTAssertEqual(o["total"].int, 2)
    }

    func testAConversationIsReadWithItsOpenQuestion() {
        let session = #"{"session":{"id":"s2","repo":"okanet/app","title":"Issue #7: Dark mode","status":"idle"},"events":["#
            + #"{"seq":1,"kind":"user","text":"Add **dark** mode"},{"seq":2,"kind":"tool","name":"Bash"},"#
            + #"{"seq":3,"kind":"text","text":"Done with the toggle."},{"seq":4,"kind":"ask","question":"Which default?","options":[{"label":"Light"},{"label":"Dark"}]}]}"#
        var o = run(.readConversation, #"{"session_id":"s2"}"#, [sessions, session])
        XCTAssertEqual(o["status"].string, "waiting for an answer")
        XCTAssertEqual(o["question"].string, "Which default?")
        XCTAssertEqual(o["options"][1].string, "Dark")
        let latest = o["latest"]
        XCTAssertEqual(latest.count, 3)
        XCTAssertEqual(latest[0]["from"].string, "user")
        XCTAssertEqual(latest[0]["text"].string, "Add dark mode")
        XCTAssertEqual(latest[2]["from"].string, "agent")
        // Another project's conversation is not read.
        o = run(.readConversation, #"{"session_id":"s3"}"#, [sessions, session])
        XCTAssertTrue(o["error"].string?.contains("not one of this project's") == true)
    }

    private let board = #"{"pulls":["#
        + #"{"number":12,"title":"Fix login","labels":[{"name":"Code-Approved"}],"checks":"success","mergeable":"mergeable"},"#
        + #"{"number":13,"title":"Dark mode","labels":[],"checks":"failure","mergeable":"conflicting","draft":true}],"#
        + #""issues":["#
        + #"{"number":7,"title":"Dark mode","labels":[{"name":"ui"}],"pulls":[{"number":13,"title":"Dark mode"}]},"#
        + #"{"number":8,"title":"Epic","subIssues":{"total":4,"completed":1}}]}"#

    func testPullRequestsSayWhetherTheyAreReadyToMerge() {
        var o = run(.listPullRequests, "{}", [board, sessions])
        let list = o["pull_requests"]
        XCTAssertEqual(o["total"].int, 2)
        XCTAssertTrue(list[0]["ready_to_merge"].is(true))
        XCTAssertEqual(list[0]["conversations"][0]["session_id"].string, "s1")
        XCTAssertTrue(list[1]["ready_to_merge"].is(false))
        XCTAssertEqual(list[1]["state"].string, "draft, has conflicts, checks failure")
        // Without the conversations, the pull requests still come.
        o = run(.listPullRequests, "{}", [board, nil])
        XCTAssertEqual(o["total"].int, 2)
        o = run(.listPullRequests, "{}", [nil])
        XCTAssertNotNil(o["error"].string)
    }

    func testAPullRequestIsReadWithItsDiffs() {
        let files = #"{"pr":{"title":"Fix login","changedFiles":2,"additions":10,"deletions":3},"files":["#
            + #"{"filename":"app/login.c","status":"modified","patch":"@@ -1 +1 @@\n-old\n+new"},{"filename":"logo.png","status":"added"}]}"#
        let o = run(.readPullRequest, #"{"number":12}"#, [files, ###"{"pr":{"body":"## Why\nThe **login** failed."}}"###])
        XCTAssertEqual(o["changed_files"].int, 2)
        XCTAssertEqual(o["lines_added"].int, 10)
        XCTAssertEqual(o["description"].string, "Why The login failed.")
        XCTAssertEqual(o["files"][0]["diff"].string, "@@ -1 +1 @@\n-old\n+new")
        XCTAssertTrue(o["files"][1]["diff"].string?.contains("binary") == true)
    }

    func testFindingsSayTheirVerdicts() {
        let findings = #"{"findings":[{"key":"a","title":"Null check","severity":"high","file":"app/x.c","line":4,"decision":"fix","fixed":true},"#
            + #"{"key":"b","title":"Naming","body":"Rename it","decision":"fix"},{"key":"c","title":"Style"}]}"#
        let o = run(.listFindings, #"{"number":12}"#, [findings])
        let list = o["findings"]
        XCTAssertEqual(list[0]["place"].string, "app/x.c line 4")
        XCTAssertEqual(list[0]["verdict"].string, "fix it")
        XCTAssertEqual(list[1]["says"].string, "Rename it")
        XCTAssertEqual(list[2]["verdict"].string, "not decided")
        XCTAssertEqual(o["to_fix"].int, 2)
        XCTAssertEqual(o["to_fix_not_fixed"].int, 1)
    }

    func testIssuesAreListedAndReadWithTheirComments() {
        var o = run(.listIssues, "{}", [board, sessions])
        let list = o["issues"]
        XCTAssertEqual(o["total"].int, 2)
        XCTAssertEqual(list[0]["pull_requests"][0].int, 13)
        XCTAssertEqual(list[0]["conversations"][0]["session_id"].string, "s2")
        XCTAssertEqual(list[1]["sub_issues"].string, "1 of 4 done")
        var timeline = #"{"events":["#
        for i in 1...7 { timeline += (i > 1 ? "," : "") + #"{"kind":"commented","actor":"dev\#(i)","body":"Comment \#(i)"}"# }
        timeline += #",{"kind":"labeled"}]}"#
        let issue = #"{"issue":{"number":7,"title":"Dark mode","state":"closed","stateReason":"not_planned","body":"Add a *dark* theme.","comments":7}}"#
        o = run(.readIssue, #"{"issue":7}"#, [issue, timeline, sessions])
        XCTAssertEqual(o["state"].string, "closed as not planned")
        XCTAssertEqual(o["description"].string, "Add a dark theme.")
        let comments = o["comments"]
        XCTAssertEqual(comments.count, 5)
        XCTAssertEqual(comments[0]["from"].string, "dev3")
        XCTAssertEqual(comments[4]["text"].string, "Comment 7")
        XCTAssertEqual(o["comments_total"].int, 7)
        XCTAssertEqual(o["conversations"][0]["session_id"].string, "s2")
    }
}
