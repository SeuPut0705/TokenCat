using System.Globalization;
using static TokenCat.Lang;

namespace TokenCat;

// SessionPresentation.swift (DESIGN §6.1, WP3): row states, groups, counts and every derived text. Pure functions of the
// readings and the model clock. "Finder" becomes File Explorer, and the resume command targets PowerShell (§8).

/// What a row shows. Derived only from the tracker's enum and exact timestamps, never re-guessed.
public enum SessionDisplayState { Input, Retrying, Tool, Working, Waiting, Complete, Interrupted, Unfinished, Idle, Measurement }

public static class SessionDisplayStateRules
{
    extension(SessionDisplayState)
    {
        /// A retry notice stays this long after its record.
        public static double RetryLimit => 600;

        /// The one urgency order: input > API retry > tool > progress > waiting for a log.
        public static IReadOnlyList<SessionDisplayState> LiveOrder =>
            [SessionDisplayState.Input, SessionDisplayState.Retrying, SessionDisplayState.Tool, SessionDisplayState.Working, SessionDisplayState.Waiting];

        /// The most urgent live state among `states`; null when none is live.
        public static SessionDisplayState? MostUrgent(IEnumerable<SessionDisplayState> states)
        {
            var present = states.ToHashSet();
            foreach (var state in SessionDisplayState.LiveOrder) if (present.Contains(state)) return state;
            return null;
        }
    }

    extension(SessionDisplayState state)
    {
        /// Shown as live in the list (includes waiting for a log).
        public bool IsLive => state.IsRunning || state == SessionDisplayState.Waiting;
        /// Counted as running. A turn waiting for the person is still open.
        public bool IsRunning => state is SessionDisplayState.Input or SessionDisplayState.Retrying or SessionDisplayState.Tool or SessionDisplayState.Working;
        /// A generation could be under way, so a missing measured speed is worth a "—".
        public bool ExpectsSpeed => state is SessionDisplayState.Retrying or SessionDisplayState.Tool or SessionDisplayState.Working;

        public string Title => state switch
        {
            SessionDisplayState.Input => Loc("입력 필요", "Input needed"),
            SessionDisplayState.Retrying => Loc("API 재시도", "API retry"),
            SessionDisplayState.Tool => Loc("도구 실행", "Running tool"),
            SessionDisplayState.Working => Loc("진행", "Working"),
            SessionDisplayState.Waiting => Loc("로그 대기", "Waiting for log"),
            SessionDisplayState.Complete => Loc("완료", "Complete"),
            SessionDisplayState.Interrupted => Loc("중단", "Interrupted"),
            SessionDisplayState.Unfinished => Loc("종료 기록 없음", "No end record"),
            SessionDisplayState.Idle => Loc("최근 활동 없음", "No recent activity"),
            _ => Loc("실측", "Measured"),
        };
    }
}

/// DesignTokens.swift `StateGlyph.Kind`: which glyph a row, chip, header or menu item draws. The App draws and colours it
/// (yellow is reserved for input).
public enum StateGlyphKind { RecordEvent, Tool, Working, Waiting, Input, Retry, Interrupted, Unfinished, Idle }

public static class StateGlyphKinds
{
    extension(StateGlyphKind)
    {
        /// A session row's glyph; null for telemetry measurement rows, which keep their own symbol.
        public static StateGlyphKind? From(SessionDisplayState state) => state switch
        {
            SessionDisplayState.Input => StateGlyphKind.Input,
            SessionDisplayState.Retrying => StateGlyphKind.Retry,
            SessionDisplayState.Tool => StateGlyphKind.Tool,
            SessionDisplayState.Working => StateGlyphKind.Working,
            SessionDisplayState.Waiting => StateGlyphKind.Waiting,
            SessionDisplayState.Interrupted => StateGlyphKind.Interrupted,
            SessionDisplayState.Unfinished => StateGlyphKind.Unfinished,
            SessionDisplayState.Complete or SessionDisplayState.Idle => StateGlyphKind.Idle,
            _ => null,
        };

        /// `StateGlyph.Kind(phase:)`: the status item's mark. Output is an event and idle has none.
        public static StateGlyphKind? From(TokenActivityState phase) => phase switch
        {
            TokenActivityState.Input => StateGlyphKind.Input,
            TokenActivityState.Tool => StateGlyphKind.Tool,
            TokenActivityState.Working => StateGlyphKind.Working,
            TokenActivityState.Stale => StateGlyphKind.Waiting,
            _ => null,
        };
    }
}

public sealed record SessionMember(TokenReading Reading, SessionDisplayState State);

/// A top-level row with the subagents that belong to it by exact session identity.
public sealed record SessionGroup(SessionMember Lead)
{
    public IReadOnlyList<SessionMember> Children { get; init; } = [];
    public string Id => Lead.Reading.Id;
    public IReadOnlyList<SessionMember> Members => [Lead, .. Children];

    public SessionDisplayState State => Lead.State == SessionDisplayState.Measurement
        ? SessionDisplayState.Measurement
        : SessionDisplayState.MostUrgent(Members.Select(member => member.State)) ?? SessionDisplayState.Idle;

    public DateTimeOffset LastActivity =>
        Members.Select(member => member.Reading.LastActivity ?? member.Reading.MeasurementAt).Max() ?? DateTimeOffset.MinValue;
}

public sealed record SessionCounts
{
    public int Input { get; init; }
    public int Retrying { get; init; }
    public int Tool { get; init; }
    public int Working { get; init; }
    public int Waiting { get; init; }
    public int Groups { get; init; }
    public int Readings { get; init; }
    public int RunningSubagents { get; init; }
    /// Readings running a tool, counted per member.
    public int ToolMembers { get; init; }
    /// Tool members by category; an unknown category counts as Other.
    public IReadOnlyDictionary<ToolCategory, int> ToolCategories { get; init; } = new Dictionary<ToolCategory, int>();
    /// The newest retry among retrying members, for the header and the flow-card caption.
    public TokenRetryState? Retry { get; init; }
    /// Every member waiting for input is a plan approval, so the copy says "승인".
    public bool InputPlansOnly { get; init; }
    public IReadOnlyDictionary<TokenSource, int> Running { get; init; } = new Dictionary<TokenSource, int>();
    /// Subscriptions a running session uses (`TokenSource.LimitProvider`): a Codex or Claude Code session, or any client's
    /// running member on a Claude or OpenAI model. LiveMonitor polls these every minute.
    public IReadOnlySet<LimitSlot> LimitSources { get; init; } = new HashSet<LimitSlot>();
    /// Newest record among waiting rows, for "N분째 새 기록 없음".
    public DateTimeOffset? WaitingSince { get; init; }
    /// Newest activity of any session group (telemetry rows excluded), for "마지막 활동 2시간 전".
    public DateTimeOffset? NewestActivity { get; init; }
    /// The same order as the group state: input > API retry > tool > working > waiting > idle; a retry reads as working.
    public TokenActivityState Phase { get; init; } = TokenActivityState.Idle;

    public int RunningGroups => Input + Retrying + Tool + Working;
    public int LiveGroups => RunningGroups + Waiting;

    public SessionCounts() { }

    public SessionCounts(IReadOnlyList<SessionGroup> groups)
    {
        Groups = groups.Count;
        var memberStates = new HashSet<SessionDisplayState>();
        var tools = new Dictionary<ToolCategory, int>();
        var running = new Dictionary<TokenSource, int>();
        var limitSources = new HashSet<LimitSlot>();
        int inputMembers = 0, planMembers = 0;
        foreach (var group in groups)
        {
            Readings += group.Members.Count;
            switch (group.State)
            {
                case SessionDisplayState.Input: Input++; break;
                case SessionDisplayState.Retrying: Retrying++; break;
                case SessionDisplayState.Tool: Tool++; break;
                case SessionDisplayState.Working: Working++; break;
                case SessionDisplayState.Waiting: Waiting++; break;
            }
            if (group.State.IsRunning)
            {
                running[group.Lead.Reading.Source] = running.GetValueOrDefault(group.Lead.Reading.Source) + 1;
            }
            if (group.State != SessionDisplayState.Measurement && group.LastActivity != DateTimeOffset.MinValue
                && (NewestActivity is not { } newest || group.LastActivity > newest)) NewestActivity = group.LastActivity;
            foreach (var member in group.Members)
            {
                memberStates.Add(member.State);
                if (member.Reading.IsSubagent && member.State.IsRunning) RunningSubagents++;
                if (group.State.IsRunning && member.State.IsRunning && member.Reading.LimitProvider is { } provider)
                    limitSources.Add(new LimitSlot(provider, member.Reading.LimitAccount));
                if (member.State == SessionDisplayState.Tool)
                {
                    ToolMembers++;
                    var category = member.Reading.ToolCategory ?? ToolCategory.Other;
                    tools[category] = tools.GetValueOrDefault(category) + 1;
                }
                if (member.State == SessionDisplayState.Input)
                {
                    inputMembers++;
                    if (SessionPresentation.IsPlanApproval(member.Reading)) planMembers++;
                }
                if (member.State == SessionDisplayState.Retrying && member.Reading.Retry is { } value && value.At >= (Retry?.At ?? DateTimeOffset.MinValue))
                    Retry = value;
                if (member.State == SessionDisplayState.Waiting && SessionPresentation.LiveAt(member.Reading) is { } at
                    && (WaitingSince is not { } since || at > since)) WaitingSince = at;
            }
        }
        ToolCategories = tools;
        Running = running;
        LimitSources = limitSources;
        InputPlansOnly = inputMembers > 0 && planMembers == inputMembers;
        Phase = PhaseOf(SessionDisplayState.MostUrgent(memberStates));
    }

    /// Swift `SessionCounts.phase(_:)`: the phase for the most urgent live state.
    public static TokenActivityState PhaseOf(SessionDisplayState? state) => state switch
    {
        SessionDisplayState.Input => TokenActivityState.Input,
        SessionDisplayState.Tool => TokenActivityState.Tool,
        SessionDisplayState.Retrying or SessionDisplayState.Working => TokenActivityState.Working,
        SessionDisplayState.Waiting => TokenActivityState.Stale,
        _ => TokenActivityState.Idle,
    };

    /// The tool category most members are running; ties go to the declaration order.
    public ToolCategory? LeadingToolCategory =>
        Enum.GetValues<ToolCategory>().Where(category => ToolCategories.GetValueOrDefault(category) > 0)
            .Cast<ToolCategory?>().MaxBy(category => ToolCategories.GetValueOrDefault(category!.Value));
}

public sealed record SpeedSlot(string? Prefix, string Value, string? Kind, bool Recent, string Help, string Spoken)
{
    public bool Known => Kind is not null;
}

/// The widget's "평균 속도" (mac `AverageSpeed`): the mean of every fresh per-session rate and the clients that contributed one,
/// fastest first (each client's own mean, descending; ties in `TokenSource` order), so the leading glyph is the fastest client.
public sealed record AverageSpeed(double Rate, IReadOnlyList<TokenSource> Sources);

/// The flow card's "지금 속도": one measured rate from one visible live session, never a sum or an average.
/// `Label`: the measured session's title, else its project (always the project for a subagent); shown when it fits.
public sealed record SpeedHeadline(string Value, string? Kind, string? Label, string Help, string Spoken)
{
    public bool Known => Kind is not null;
}

/// Context occupied by the latest request: a percentage only when the client logged the window size.
public sealed record ContextSlot(string Text, string Short, double? Fraction, bool Warning, string? Compacted, string Help, string Spoken);

/// An account usage-limit window as last recorded: Codex from its logs, Claude from the status line bridge or the Claude
/// desktop app's history (no reset time); either one from omp's or Pi's own usage check (`RecordedBy`, its record time) or
/// from a live poll (LiveLimits). Never projected forward.
public sealed record UsageLimitSummary(double UsedPercent, int? WindowMinutes, DateTimeOffset? ResetsAt, DateTimeOffset RecordedAt)
{
    public TokenSource Source { get; init; } = TokenSource.Codex;
    /// The other live window (Claude's two, Codex's 5-hour beside its weekly), drawn as its own compact row.
    public OtherWindow? Other { get; init; }
    /// Read from OpenAI or Anthropic by a live poll; `RecordedAt` is that poll.
    public bool Live { get; init; }
    /// "omp" or "Pi" when that client's own usage check recorded the value; named beside the record age.
    public string? RecordedBy { get; init; }
    public LimitAccount? Account { get; init; }
    public string? AccountLabel { get; init; }

    /// A live poll in the last 2 minutes: "실시간" takes the place of the record age.
    public bool IsLive(DateTimeOffset now) => Live && (now - RecordedAt).TotalSeconds < LiveLimits.LiveFor;

    /// `RecordedAt`: its own record when it differs from the shown window's (Codex logs each window apart), with its own
    /// `Live` and `RecordedBy`; null: the same record as the shown window.
    public sealed record OtherWindow(double UsedPercent, int WindowMinutes, DateTimeOffset ResetsAt)
    {
        public DateTimeOffset? RecordedAt { get; init; }
        public bool Live { get; init; }
        public string? RecordedBy { get; init; }
    }

    /// The other window as a summary of its own, for its compact row; null once it has reset.
    public UsageLimitSummary? OtherSummary(DateTimeOffset now)
    {
        if (Other is not { } other || other.ResetsAt <= now) return null;
        var own = other.RecordedAt is not null;
        return new UsageLimitSummary(other.UsedPercent, other.WindowMinutes, other.ResetsAt, other.RecordedAt ?? RecordedAt)
            { Source = Source, Live = own ? other.Live : Live, RecordedBy = own ? other.RecordedBy : RecordedBy,
                Account = Account, AccountLabel = AccountLabel };
    }

    /// When the window resets; without a logged reset time, one full window after the record.
    public DateTimeOffset? ResetDate => ResetsAt ?? (WindowMinutes is int minutes and > 0 ? RecordedAt.AddMinutes(minutes) : null);
    public bool Expired(DateTimeOffset now) => ResetDate is { } reset && reset <= now;
    /// A reset window stays on screen for one day to say "초기화됨", then the row goes away.
    public bool IsShown(DateTimeOffset now) => !Expired(now) || (now - (ResetDate ?? DateTimeOffset.MinValue)).TotalSeconds < 86_400;
    string Name => Source.ShortTitle;
    /// "Claude", not "Claude Code": the window belongs to the Claude account, whichever app used it.
    public string Title
    {
        get
        {
            var window = SessionPresentation.WindowLabel(WindowMinutes);
            return Loc($"{Name} {window} 한도", $"{Name} {window} limit");
        }
    }
    /// The on-screen row name, "Claude · 5-hour": provider first so the rows scan by provider; `Title` stays for Narrator.
    public string ShortTitle => $"{Name} · {SessionPresentation.WindowLabel(WindowMinutes)}";
    /// The number alone ("28"); "%" and " 사용" are drawn smaller beside it.
    public string PercentText => SessionPresentation.Round(UsedPercent).ToString(CultureInfo.InvariantCulture);
    public string Value(DateTimeOffset now) => Expired(now) ? "—" : Loc($"{PercentText}% 사용", $"{PercentText}% used");
    /// More than 10 minutes since the client reported it: the value is shown weaker.
    public bool IsOld(DateTimeOffset now) => (now - RecordedAt).TotalSeconds > 600;
    string WaitingText => Loc($"초기화됨 · 다음 {Name} 기록 대기", $"Reset · waiting for a {Name} record");

    /// "4분 전 기록", or "omp 4분 전 기록" when another client recorded it; `start` capitalizes the English sentence start.
    string Recorded(string age, bool start = false) => RecordedBy is { } by
        ? Loc($"{by} {age} 기록", $"{by} recorded {age}")
        : Loc($"{age} 기록", start ? $"Recorded {age}" : $"recorded {age}");

    /// Help and VoiceOver wording.
    public string Detail(DateTimeOffset now, bool spoken = false)
    {
        if (Expired(now)) return WaitingText;
        var age = SessionPresentation.HelpAge(RecordedAt, now, spoken);
        var basis = RecordedBy is { } by ? Loc($"{by} {age} 기록 기준", $"as of {by}'s record {age}") : Loc($"{age} 기록 기준", $"as of {age}");
        if (ResetsAt is not { } resetsAt) return IsLive(now) ? Loc("실시간", "Live") : RecordedBy is null ? Loc($"{age} 기록 기준", $"As of {age}") : basis;
        var reset = SessionPresentation.Countdown(resetsAt, now, spoken);
        return Loc($"{reset} 후 초기화 · ", $"Resets in {reset} · ") + (IsLive(now) ? Loc("실시간", "live") : basis);
    }

    /// On-screen variants, widest first; the reset countdown is never the part that is dropped, the recording client is
    /// dropped before the age.
    public IReadOnlyList<string> Details(DateTimeOffset now)
    {
        if (Expired(now)) return [WaitingText];
        var age = SessionPresentation.HelpAge(RecordedAt, now);
        if (ResetsAt is not { } resetsAt) return [IsLive(now) ? Loc("실시간", "Live") : Recorded(age, start: true)];
        var countdown = SessionPresentation.Countdown(resetsAt, now);
        var reset = Loc($"{countdown} 후 초기화", $"Resets in {countdown}");
        if (IsLive(now)) return [reset + " · " + Loc("실시간", "live"), reset];
        return [.. RecordedBy is null ? [] : new[] { reset + " · " + Recorded(age) }, reset + " · " + Loc($"{age} 기록", $"recorded {age}"), reset];
    }

    /// "주간 한도 31% 사용 · 3일 4시간 후 초기화" while the other window has not reset.
    public string? OtherText(DateTimeOffset now, bool spoken = false)
    {
        if (Other is not { } other || other.ResetsAt <= now) return null;
        var window = SessionPresentation.WindowLabel(other.WindowMinutes);
        var percent = SessionPresentation.Round(other.UsedPercent);
        var reset = SessionPresentation.Countdown(other.ResetsAt, now, spoken);
        return Loc($"{window} 한도 {percent}% 사용 · {reset} 후 초기화",
                   $"{char.ToUpperInvariant(window[0])}{window[1..]} limit {percent}% used · resets in {reset}");
    }

    public string Spoken(DateTimeOffset now)
    {
        var main = Expired(now) ? WaitingText.Replace(" · ", ", ")
            : Loc($"{PercentText}퍼센트 사용", $"{PercentText} percent used") + ", " + Detail(now, spoken: true).Replace(" · ", ", ");
        return (AccountLabel is { } label ? label + ", " : "") + main + (OtherText(now, spoken: true) is { } other
            ? ", " + other.Replace("%", Loc("퍼센트", " percent")).Replace(" · ", ", ") : "");
    }

    public string Help(DateTimeOffset now)
    {
        // Usage limits come from the telemetry clients only (Codex and Claude Code).
        var basis = (Live, Source) switch
        {
            (true, TokenSource.Codex) => Loc("Codex에 저장된 로그인으로 OpenAI에서 확인한 계정 사용량입니다.", "Account usage checked with OpenAI using Codex's saved sign-in."),
            (true, TokenSource.Claude) => Loc("Claude Code에 저장된 로그인으로 Anthropic에서 확인한 계정 사용량입니다.", "Account usage checked with Anthropic using Claude Code's saved sign-in."),
            (false, _) when RecordedBy is { } by => Loc($"{by}가 자체 사용량 확인으로 기록한 마지막 {Name} 계정 사용량입니다. 실시간 잔여량이 아니며 {by}를 사용할 때만 갱신됩니다.",
                $"The last {Name} account usage {by} recorded from its own usage check. It isn't a live balance and updates only while you use {by}."),
            (false, TokenSource.Codex) => Loc("Codex 로그에 마지막으로 기록된 계정 사용량입니다. 실시간 잔여량이 아니며 Codex를 사용할 때만 갱신됩니다.",
                "The last account usage recorded in the Codex logs. It isn't a live balance and updates only while you use Codex."),
            (false, TokenSource.Claude) => Loc("Claude Code가 상태 표시줄로 보냈거나 Claude 데스크톱 앱이 기록한 마지막 Claude 계정 사용량입니다. 실시간 잔여량이 아니며 Claude를 사용할 때만 갱신됩니다.",
                "The last Claude account usage sent by Claude Code to its status line or recorded by the Claude desktop app. It isn't a live balance and updates only while you use Claude."),
            _ => "",
        } + (Live ? Loc(" 이 계정의 모델을 쓰는 세션이 실행 중이거나 창이 열려 있으면 1분마다, 그 밖에는 10분마다 확인합니다.",
                        " It's checked every minute while a session on its models runs or this window is open, otherwise every 10 minutes.") : "");
        return (AccountLabel is { } label ? label + "\n" : "") + basis + Loc(" 소진 시점을 예측하지 않습니다.", " TokenCat doesn't predict when you'll reach it.")
            + (OtherText(now) is { } other ? "\n" + other : "");
    }

    /// One compact window line; help and spoken text keep the longer wording.
    public sealed record WindowLine(string WindowLabel, double UsedPercent, DateTimeOffset? ResetsAt, bool Expired, bool Old)
    {
        public static string Label(int? minutes)
        {
            if (Lang.Current != AppLanguage.En || minutes is not > 0) return SessionPresentation.WindowLabel(minutes);
            return minutes.Value switch
            {
                10_080 => "Week",
                43_200 or 43_800 => "Month",
                var value when value % 1_440 == 0 => $"{value / 1_440}d",
                var value when value % 60 == 0 => $"{value / 60}h",
                var value => $"{value}m",
            };
        }

        public string PercentText => SessionPresentation.Round(UsedPercent).ToString(CultureInfo.InvariantCulture);
        public string? Reset(DateTimeOffset now) => Expired ? Loc("초기화됨", "Reset")
            : ResetsAt is { } reset ? SessionPresentation.Countdown(reset, now) : null;
    }

    /// Shortest window first, retaining each window's own record age.
    public IReadOnlyList<WindowLine> WindowLines(DateTimeOffset now)
    {
        var main = new WindowLine(WindowLine.Label(WindowMinutes), UsedPercent, ResetsAt, Expired(now), IsOld(now));
        if (OtherSummary(now) is not { } other) return [main];
        var second = new WindowLine(WindowLine.Label(other.WindowMinutes), other.UsedPercent, other.ResetsAt, false, other.IsOld(now));
        return (WindowMinutes ?? int.MaxValue) <= (other.WindowMinutes ?? int.MaxValue) ? [main, second] : [second, main];
    }

    /// Every displayed window must be fresh before the account card claims live provenance.
    public bool AllLive(DateTimeOffset now) => IsLive(now) && (OtherSummary(now)?.IsLive(now) ?? true);

    /// Say the oldest non-live displayed window's recorder and age once per account.
    public string Provenance(DateTimeOffset now)
    {
        if (AllLive(now)) return Loc("실시간", "Live");
        var other = OtherSummary(now);
        var stale = !IsLive(now) ? this : other ?? this;
        if (other is not null && !other.IsLive(now) && other.RecordedAt < stale.RecordedAt) stale = other;
        var age = SessionPresentation.HelpAge(stale.RecordedAt, now);
        return stale.RecordedBy is { } by ? $"{by} · {age}" : age;
    }

    /// Shorten e-mail names only when distinct full labels will still read distinctly.
    public static IReadOnlyList<string?> CompactAccountLabels(IReadOnlyList<UsageLimitSummary> limits)
    {
        var shortened = limits.Select(limit => limit.AccountLabel is { } label
            ? string.Join(" ", label.Split(' ').Select(word => word.IndexOf('@') is var at && at > 0 ? word[..at] : word))
            : null).ToArray();
        return limits.Select((limit, index) => shortened[index] is { } label
            && limits.Where((other, otherIndex) => other.AccountLabel != limit.AccountLabel && shortened[otherIndex] == label).Any()
                ? limit.AccountLabel : shortened[index]).ToArray();
    }
}

public enum TelemetryNoticeKind { PortBusy, Busy, Collector, Conflict, Failed, Off, Expired, Restart }

/// Why the footer warns about telemetry; copy stays short enough for the footer.
public sealed record TelemetryNotice(TelemetryNoticeKind Kind, string Text, string Help)
{
    public bool IsProblem => Kind != TelemetryNoticeKind.Restart;
    /// The collector itself is not running, so no client config was touched.
    public bool CollectorDown => Kind is TelemetryNoticeKind.PortBusy or TelemetryNoticeKind.Busy or TelemetryNoticeKind.Collector or TelemetryNoticeKind.Off;
}

/// The flyout header sentence (H-2): the one place that summarises session state.
public sealed record HeaderStatus(string Sentence, string Suffix, StateGlyphKind? Glyph, string Help)
{
    /// "기록 확인 중": the sentence itself is secondary.
    public bool Muted { get; init; }
    public RunnerHead Head { get; init; } = RunnerHead.Normal;
    public string Spoken => Sentence + Suffix;
}

/// The flow card's caption slot above the last-record value (F-2).
public sealed record FlowCaption(string Text, string Help)
{
    public StateGlyphKind? Glyph { get; init; }
    /// Retry captions are primary; the rest stay secondary.
    public bool Emphasized { get; init; }
}

public enum FooterStatusKind { Loading, AiDelay, SystemDelay, Notice, Live }

/// The footer's single leading item (9), by priority.
public sealed record FooterStatus(FooterStatusKind Kind, string Text);

/// DashboardView.swift `OnboardingCard.Outcome`: the first-run card says only what actually happened. The card itself is the App's.
public abstract record OnboardingOutcome
{
    public sealed record Added(bool Bridged) : OnboardingOutcome;
    public sealed record Skipped(string Reason) : OnboardingOutcome;
    public sealed record Failed(string Reason) : OnboardingOutcome;
    public sealed record CollectorDown(string Text) : OnboardingOutcome;
    public sealed record Preparing : OnboardingOutcome;

    /// Starts the connect failure note, which the card strips to show only the reason.
    public static string NotePrefix => Loc("실측 연결: ", "Telemetry: ");

    /// `bridged`: Claude Code settings run the usage-limit bridge.
    public static OnboardingOutcome Make(TelemetryNotice? notice, string? note, TelemetrySetupFailure? failure, TelemetryCollectorState state,
                                         bool bridged = false, bool optedOut = false)
    {
        if (notice is { CollectorDown: true }) return new CollectorDown(notice.Text);
        if (optedOut) return new Skipped(Loc("실측 연결을 해제한 상태입니다 · 설정 › 실측에서 다시 연결", "Telemetry is disconnected · reconnect in Settings › Telemetry"));
        if (note is not null)
        {
            var reason = note.Replace(NotePrefix, "");
            return failure is TelemetrySetupFailure.Conflict or TelemetrySetupFailure.Invalid ? new Skipped(reason) : new Failed(reason);
        }
        return state == TelemetryCollectorState.Starting ? new Preparing() : new Added(bridged);
    }
}

/// The calendar for the expanded list's date captions (Swift passes a `Calendar`).
public sealed record DayCalendar(TimeZoneInfo Zone, DayOfWeek FirstDay)
{
    public static DayCalendar Current => new(TimeZoneInfo.Local, Lang.Culture.DateTimeFormat.FirstDayOfWeek);
}

/// The inline detail line under a clicked row (S-6). `Copy` is what the copy button puts on the clipboard; null draws none.
public sealed record DetailItem(string Label, string Value, string? Copy = null)
{
    public string Id => Label;
}

/// Copy or reveal only; file contents are never opened. `Symbol` is the mac SF Symbol name, kept as the App's icon key.
public sealed record RowAction(string Title, string Symbol, string? Copy = null, string? Reveal = null)
{
    public string Id => Title;
    public bool IsReveal => Reveal is not null;
}

public static partial class Format
{
    /// "4:12" since `date`, "—" without one.
    public static string Elapsed(DateTimeOffset? date, DateTimeOffset now) =>
        date is { } at ? SessionPresentation.Clock(Math.Max(0, (int)(now - at).TotalSeconds)) : "—";
}

public static class SessionPresentation
{
    static readonly TokenSource[] Sources = Enum.GetValues<TokenSource>();
    static string Names(IEnumerable<TokenSource> sources) => string.Join(Loc("·", " and "), Sources.Where(sources.Contains).Select(source => source.Title));

    /// Swift `.rounded()`: half away from zero (printf-style F0 would round half to even).
    internal static int Round(double value) => (int)Math.Round(value, MidpointRounding.AwayFromZero);
    static double Seconds(DateTimeOffset a, DateTimeOffset b) => (a - b).TotalSeconds;

    // Swift `prefix`/`suffix` count characters (grapheme clusters).
    internal static string Prefix(string text, int count)
    {
        var info = new StringInfo(text);
        return info.LengthInTextElements <= count ? text : info.SubstringByTextElements(0, count);
    }

    internal static string Suffix(string text, int count)
    {
        var info = new StringInfo(text);
        return info.LengthInTextElements <= count ? text : info.SubstringByTextElements(info.LengthInTextElements - count);
    }

    // `URL(fileURLWithPath:).lastPathComponent` / `.deletingPathExtension()` on ids and Codex agent paths, which use "/" (rule 7).
    static string LastComponent(string path)
    {
        var trimmed = path.TrimEnd('/');
        return trimmed.Length == 0 ? path : trimmed[(trimmed.LastIndexOf('/') + 1)..];
    }

    static string DeletingExtension(string name) => name.LastIndexOf('.') is > 0 and var dot ? name[..dot] : name;

    /// `localizedStandardCompare`: case- and width-insensitive with numeric runs compared as numbers.
    public static int StandardCompare(string a, string b) =>
        CultureInfo.InvariantCulture.CompareInfo.Compare(a, b, CompareOptions.IgnoreCase | CompareOptions.IgnoreWidth | CompareOptions.NumericOrdering);

    public static bool IsTelemetry(TokenReading reading) => reading.Id.StartsWith("telemetry:", StringComparison.Ordinal);

    /// Newest record of any kind: liveness only.
    public static DateTimeOffset? LiveAt(TokenReading reading) =>
        reading.LastActivity is { } a && reading.LastLogAt is { } b ? (a > b ? a : b) : reading.LastActivity ?? reading.LastLogAt;

    public static bool IsRetrying(TokenReading reading, DateTimeOffset now)
    {
        if (reading.Retry is not { } retry) return false;
        var age = Seconds(now, retry.At);
        return age >= -5 && age <= SessionDisplayState.RetryLimit;
    }

    public static SessionDisplayState DisplayState(TokenReading reading, DateTimeOffset now)
    {
        if (IsTelemetry(reading)) return SessionDisplayState.Measurement;
        switch (reading.ActivityState)
        {
            case TokenActivityState.Input: return SessionDisplayState.Input;
            case TokenActivityState.Unfinished: return SessionDisplayState.Unfinished;
            // The tracker ends "로그 대기" 30 minutes after the newest record (then Unfinished); the UI does not re-time it.
            case TokenActivityState.Stale: return SessionDisplayState.Waiting;
        }
        if (!reading.Active)
            return reading.ActivityState switch
            {
                TokenActivityState.Complete => SessionDisplayState.Complete,
                TokenActivityState.Interrupted => SessionDisplayState.Interrupted,
                _ => SessionDisplayState.Idle,
            };
        if (IsRetrying(reading, now)) return SessionDisplayState.Retrying;
        if (reading.ActivityState == TokenActivityState.Tool) return SessionDisplayState.Tool;
        // A fresh output record is an event shown by the hero dot, the row's last-record line and the cat's run.
        return SessionDisplayState.Working;
    }

    /// Subagents fold under the main row with the same source and exact session identity.
    /// Model, project and time never establish a group; telemetry rows never group.
    public static List<SessionGroup> Groups(IReadOnlyList<TokenReading> readings, DateTimeOffset now)
    {
        static string? Key(TokenSource source, string? session) => session is null ? null : source.Id + "\u001f" + session;
        var sorted = readings.OrderBy(reading => reading.Id, StringComparer.Ordinal).ToList();
        var groups = new List<(SessionMember Lead, List<SessionMember> Children)>();
        var parentIndex = new Dictionary<string, int>();
        foreach (var reading in sorted.Where(reading => IsTelemetry(reading) || !reading.IsSubagent))
        {
            groups.Add((new SessionMember(reading, DisplayState(reading, now)), []));
            if (IsTelemetry(reading) || Key(reading.Source, reading.SessionID) is not { } key) continue;
            if (parentIndex.TryGetValue(key, out var existing)
                && (groups[existing].Lead.Reading.LastActivity ?? DateTimeOffset.MinValue) >= (reading.LastActivity ?? DateTimeOffset.MinValue)) continue;
            parentIndex[key] = groups.Count - 1;
        }
        foreach (var reading in sorted.Where(reading => !IsTelemetry(reading) && reading.IsSubagent))
        {
            var member = new SessionMember(reading, DisplayState(reading, now));
            if (Key(reading.Source, reading.ParentSessionID ?? reading.SessionID) is { } key && parentIndex.TryGetValue(key, out var index))
                groups[index].Children.Add(member);
            else groups.Add((member, []));
        }
        // A lead quiet past its allowance while a subagent still runs is waiting on that subagent (a long Agent call).
        return groups.Select(group => new SessionGroup(
            group.Lead.State is SessionDisplayState.Waiting or SessionDisplayState.Unfinished && group.Children.Any(child => child.State.IsRunning)
                ? group.Lead with { State = SessionDisplayState.Tool } : group.Lead) { Children = group.Children }).ToList();
    }

    public static string AgentLabel(TokenReading reading)
    {
        if (reading.AgentID is { Length: > 0 } agent) return agent.Contains('/') ? LastComponent(agent) : Prefix(agent, 8);
        return Suffix(reading.SessionID ?? DeletingExtension(LastComponent(reading.Id)), 8);
    }

    /// The client's role name for help and VoiceOver; only known internal names are translated.
    public static string? RoleLabel(string? role)
    {
        if (role?.Trim() is not { Length: > 0 } trimmed) return null;
        return trimmed is "guardian" or "guardian_review" ? Loc("자동 검토", "Auto review") : trimmed;
    }

    /// Roles nearly every Claude Code subagent shares; as a title they would hide the only distinguishing ID.
    public static readonly IReadOnlySet<string> OpaqueRoles = new HashSet<string> { "workflow-subagent", "general-purpose" };

    /// A distinguishing role or nickname first; the ID follows in the detail slot. Without one (no role, or a shared one)
    /// the row reads "하위 에이전트 · a2222222", the ID still telling siblings apart.
    public static (string Title, string? Detail) ChildTitle(TokenReading reading)
    {
        var role = DistinguishingRole(reading);
        if (reading.AgentID is { } agent && agent.Contains('/'))
        {
            var name = LastComponent(agent);
            return (name, role == name ? null : role);
        }
        return (role ?? Loc("하위 에이전트", "Subagent"), AgentLabel(reading));
    }

    /// The subagent's own name inside another sentence ("subagent Explore", "subagent a2222222"): its path name, role or
    /// ID, never the generic "Subagent" title.
    public static string ChildName(TokenReading reading) =>
        reading.AgentID is { } agent && agent.Contains('/') ? LastComponent(agent) : DistinguishingRole(reading) ?? AgentLabel(reading);

    static string? DistinguishingRole(TokenReading reading) =>
        RoleLabel(reading.AgentRole) is { } label && !OpaqueRoles.Contains(label) ? label : null;

    /// UUIDv7 prefixes are timestamps shared by conversations created together, so use the suffix.
    public static string ShortID(TokenReading reading)
    {
        if (reading.IsSubagent) return AgentLabel(reading);
        if (reading.SessionID is { Length: > 0 } session) return Suffix(session, 8);
        if (IsTelemetry(reading)) return "";
        return Suffix(DeletingExtension(LastComponent(reading.Id)), 8);
    }

    /// A child shows its own project when it differs from the parent's.
    public static string? ChildProjectSuffix(TokenReading child, TokenReading parent) =>
        child.Project is { Length: > 0 } project && project != parent.Project ? project : null;

    /// A lead or stand-alone row's name: the client's session title, else the project folder.
    public static string RowTitle(TokenReading reading) => reading.Title ?? reading.Project ?? Loc("프로젝트 미확인", "Unknown project");

    /// The project beside a titled row's name, so the folder stays visible; null when the project is the name.
    public static string? RowProject(TokenReading reading) =>
        reading.Title is not null && reading.Project is { Length: > 0 } project ? project : null;

    /// A titled row's hover line: the whole title (the row cuts it) and the project.
    public static string? TitleHelp(TokenReading reading) =>
        reading.Title is { } title ? string.Join(" · ", new[] { title, reading.Project }.OfType<string>()) : null;

    /// A live row's second line, one text with one separator: "Claude Code · claude-opus-5-5 · xhigh"; a titled row
    /// leads with its project ("TokenCat · Claude Code · …").
    public static string ClientLine(TokenReading reading) =>
        string.Join(" · ", new[] { RowProject(reading), reading.ClientTitle, reading.Model ?? Loc("모델 기록 대기", "waiting for model"), EffortLabel(reading) }
            .OfType<string>());

    /// Raw client value, lowercased and never translated.
    public static string? EffortLabel(TokenReading reading) => reading.Effort?.Trim() is { Length: > 0 } effort ? effort.ToLowerInvariant() : null;

    public static string ToolTitle(ToolCategory? category) => category switch
    {
        ToolCategory.Command => Loc("명령 실행", "Running command"),
        ToolCategory.File => Loc("파일 작업", "File operation"),
        ToolCategory.Web => Loc("웹 조회", "Web lookup"),
        ToolCategory.Agent => Loc("하위 에이전트 대기", "Waiting for subagent"),
        ToolCategory.Mcp => Loc("MCP 도구 실행", "MCP tool"),
        ToolCategory.Question => Loc("입력 요청", "Input request"),
        _ => Loc("도구 실행", "Running tool"),
    };

    /// The tool category replaces the generic "도구 실행".
    public static string StateTitle(SessionDisplayState state, TokenReading reading) =>
        state == SessionDisplayState.Tool ? ToolTitle(reading.ToolCategory) : state.Title;

    /// A live row's chip: tool category, input kind, or the state. Retry progress stays on line 2.
    public static string ChipText(SessionDisplayState state, TokenReading reading) =>
        state == SessionDisplayState.Input ? InputTitle(reading) : StateTitle(state, reading);

    public static bool IsPlanApproval(TokenReading reading) => reading.ToolName == "ExitPlanMode";

    public static string InputTitle(TokenReading reading) =>
        IsPlanApproval(reading) ? Loc("계획 승인 대기", "Waiting for plan approval") : Loc("질문 답변 대기", "Waiting for an answer");

    /// An idle lead row standing in for its live children.
    public static string ChildGroupText(SessionDisplayState state, int count)
    {
        var children = Plural(count, "subagent");
        return state switch
        {
            SessionDisplayState.Input => Loc($"하위 {count}개 입력 필요", $"{children} {(count == 1 ? "needs" : "need")} input"),
            SessionDisplayState.Retrying => Loc($"하위 {count}개 API 재시도", $"{children} in API retry"),
            _ => Loc($"하위 {count}개 {(state.IsRunning ? "진행 중" : "로그 대기")}", $"{children} {(state.IsRunning ? "working" : "waiting for log")}"),
        };
    }

    /// VoiceOver row label (P-3): "<상태>, [<제목>,] <프로젝트>, <클라이언트> <모델>"; subagents "하위 에이전트 <제목>, <상태>".
    public static string SpokenLabel(TokenReading reading, SessionDisplayState state)
    {
        var word = StateTitle(state, reading);
        if (reading.IsSubagent)
            return Loc($"하위 에이전트 {ChildName(reading)}, {word}", $"Subagent {ChildName(reading)}, {word}");
        var name = string.Join(", ", new[] { reading.Title, reading.Project ?? Loc("프로젝트 미확인", "Unknown project") }.OfType<string>());
        return $"{word}, {name}, {reading.ClientTitle} {reading.Model ?? Loc("모델 미확인", "unknown model")}";
    }

    /// "재시도 2/10 · 4초 후" / "Retry 2/10 · in 4s"; `api` starts it "API 재시도" / "API retry".
    public static string RetryText(TokenRetryState retry, DateTimeOffset now, bool api = false, bool spoken = false)
    {
        var attempts = retry.MaxAttempts is { } max ? $"{retry.Attempt}/{max}" : Loc($"{retry.Attempt}회째", $"#{retry.Attempt}");
        var head = (api ? Loc("API 재시도", "API retry") : Loc("재시도", "Retry")) + $" {attempts} · ";
        if (retry.NetworkDown) return head + Loc("네트워크 끊김", "network down");
        if (retry.RetryAt is not { } at || at <= now) return head + Loc("재요청 중", "retrying now");
        var seconds = (int)Math.Ceiling(Seconds(at, now));
        return head + Format.Later(seconds >= 60 ? Format.Span(seconds / 60, Format.TimeUnit.Minute, spoken) : Format.Span(seconds, Format.TimeUnit.Second, spoken));
    }

    /// Shared with the views, which mark a record this fresh.
    public static string JustNow => Loc("방금", "just now");
    /// The flow card's default caption; the views compare against it.
    public static string LastRecordCaption => Loc("마지막 기록", "Last record");

    /// Output ages on rows and the flow card: "방금" / "just now" under 10 s, then 10 s steps, then `Format.Age`.
    public static string RecordAge(DateTimeOffset date, DateTimeOffset now, bool spoken = false)
    {
        var seconds = Math.Max(0, (int)Seconds(now, date));
        if (seconds < 10) return JustNow;
        if (seconds < 60) return Format.Ago(Format.Span(seconds / 10 * 10, Format.TimeUnit.Second, spoken));
        return Format.Age(date, now, spoken);
    }

    /// The current turn's last output record for a row's third line; null when it belongs to an earlier turn.
    public static TokenOutputEvent? LastRecord(TokenReading reading)
    {
        if (reading.LastOutputAt is not { } at || reading.LastOutputDelta is not ({ } tokens and > 0)) return null;
        if (reading.CurrentTurnStartedAt is { } start && at < start) return null;
        return new TokenOutputEvent(at, tokens);
    }

    public static bool IsFresh(DateTimeOffset date, DateTimeOffset now)
    {
        var age = Seconds(now, date);
        return age >= -FlowSeries.FutureTolerance && age <= FlowSeries.FreshSeconds;
    }

    public const double CompactionWindow = 1_800;

    public static ContextSlot? Context(TokenReading reading, DateTimeOffset now)
    {
        if (reading.Context is not { UsedTokens: > 0 } context) return null;
        var source = reading.ClientTitle;
        string text, @short, spoken, help;
        double? fraction = null;
        var warning = false;
        if (context.WindowTokens is { } window and > 0)
        {
            var percent = Round((double)context.UsedTokens / window * 100);
            (text, @short, spoken) = (Loc($"컨텍스트 {percent}% 사용", $"Context {percent}% used"), $"{percent}%",
                                      Loc($"컨텍스트 {percent}퍼센트 사용", $"Context {percent} percent used"));
            fraction = Math.Min(1, (double)context.UsedTokens / window);
            warning = percent >= 85;
            help = Loc($"마지막 요청 입력 {Format.Tokens(context.UsedTokens)} / 모델 컨텍스트 {Format.Tokens(window)} tok ({source} 기록)",
                       $"Last request input {Format.Tokens(context.UsedTokens)} / model context {Format.Tokens(window)} tok (recorded by {source})");
        }
        else
        {
            var used = context.UsedTokens;
            @short = used < 1_000 ? used.ToString(CultureInfo.InvariantCulture)
                : used < 999_500 ? $"{Round(used / 1_000.0)}k" : Format.CompactTokens(used);
            (text, spoken) = (Loc($"컨텍스트 {@short}", $"Context {@short}"), Loc($"컨텍스트 {used} 토큰", $"Context {used} tokens"));
            help = Loc($"마지막 요청 입력 {Format.Tokens(used)} tok (입력·캐시 합계)\n{source}는 컨텍스트 창 크기를 기록하지 않아 비율을 표시하지 않습니다",
                       $"Last request input {Format.Tokens(used)} tok (input and cache)\n{source} doesn't record the context window size, so no percentage is shown");
        }
        help += Loc($"\n출력 토큰 제외 · {HelpAge(context.RecordedAt, now)} 기록", $"\nExcludes output tokens · recorded {HelpAge(context.RecordedAt, now)}");
        string? compacted = null;
        if (context.CompactedAt is { } at)
        {
            help += Loc($"\n압축 완료 기록 {HelpAge(at, now)}", $"\nCompaction recorded {HelpAge(at, now)}");
            var age = Seconds(now, at);
            if (age >= -FlowSeries.FutureTolerance && age < CompactionWindow) compacted = Loc($"압축 {Format.Age(at, now)}", $"Compacted {Format.Age(at, now)}");
        }
        return new ContextSlot(text, @short, fraction, warning, compacted, help, spoken);
    }

    /// A completed turn's output and the client's own duration, side by side and never divided.
    public static string? LastTurnSummary(TokenReading reading)
    {
        if (reading.LastOutputTokens is not { } output) return null;
        if (reading.LastTurnDurationSeconds is not { } seconds || !double.IsFinite(seconds) || seconds < 0)
            return Loc($"마지막 출력 기록 {Format.Tokens(output)} tok", $"Last output record: {Format.Tokens(output)} tok");
        var took = Clock(Round(seconds));
        return Loc($"마지막 완료 턴 출력 {Format.Tokens(output)} tok · 소요 {took}", $"Last completed turn: {Format.Tokens(output)} tok · took {took}");
    }

    public static string Clock(int seconds) => seconds >= 3_600
        ? $"{seconds / 3_600}:{seconds / 60 % 60:00}:{seconds % 60:00}"
        : $"{seconds / 60}:{seconds % 60:00}";

    /// Minute-granular age for help text, so tooltips do not change every second.
    public static string HelpAge(DateTimeOffset? date, DateTimeOffset now, bool spoken = false) =>
        date is { } at && Seconds(now, at) < 60 ? Loc("1분 이내", spoken ? "less than a minute ago" : "<1m ago") : Format.Age(date, now, spoken);

    /// Time left, minute-granular: "2시간 13분" / "2h 13m", "5일 11시간" / "5d 11h", "1분 이내" / "<1m".
    public static string Countdown(DateTimeOffset date, DateTimeOffset now, bool spoken = false)
    {
        var minutes = Math.Max(0, (int)Seconds(date, now) / 60);
        string Pair(int big, Format.TimeUnit bigUnit, int small, Format.TimeUnit smallUnit) =>
            Format.Span(big, bigUnit, spoken) + (small > 0 ? " " + Format.Span(small, smallUnit, spoken) : "");
        if (minutes >= 1_440) return Pair(minutes / 1_440, Format.TimeUnit.Day, minutes % 1_440 / 60, Format.TimeUnit.Hour);
        if (minutes >= 60) return Pair(minutes / 60, Format.TimeUnit.Hour, minutes % 60, Format.TimeUnit.Minute);
        return minutes > 0 ? Format.Span(minutes, Format.TimeUnit.Minute, spoken) : Loc("1분 이내", spoken ? "less than a minute" : "<1m");
    }

    public static string WindowLabel(int? minutes) => minutes switch
    {
        null or <= 0 => Loc("사용", "usage"),
        300 => Loc("5시간", "5-hour"),
        10_080 => Loc("주간", "weekly"),
        43_200 or 43_800 => Loc("월간", "monthly"),
        { } m when m % 1_440 == 0 => Loc($"{m / 1_440}일", $"{m / 1_440}-day"),
        { } m when m % 60 == 0 => Loc($"{m / 60}시간", $"{m / 60}-hour"),
        { } m => Loc($"{m}분", $"{m}-minute"),
    };

    /// Replay-proof per window length: its newest reset wins, then the highest percentage inside it. Among windows that have
    /// not reset the higher use wins (a tie goes to the longer window); when all have reset, the latest reset.
    /// Without any reset time the windows cannot be told apart, so only the newest record counts.
    /// `reads`: the windows of the newest live poll (LiveLimits) and of omp's or Pi's own usage checks, weighed with the log
    /// records like more sessions.
    public static UsageLimitSummary? UsageLimit(IReadOnlyList<TokenReading> readings, DateTimeOffset now, IReadOnlyList<TokenRateLimit>? reads = null)
    {
        // Live polls last: past 2 minutes old they lose a tie to a later record of the same value.
        var limits = readings.Where(reading => reading.Source == TokenSource.Codex).Select(reading => reading.RateLimit).OfType<TokenRateLimit>()
            .Concat(reads ?? []).Where(limit => double.IsFinite(limit.UsedPercent)).ToList();
        if (limits.Count == 0) return null;
        if (limits.All(limit => limit.ResetsAt is null))
        {
            var last = limits.MaxBy(limit => limit.RecordedAt)!;
            return new UsageLimitSummary(last.UsedPercent, last.WindowMinutes, null, last.RecordedAt) { Live = last.Live, RecordedBy = last.RecordedBy };
        }
        // A live poll overrides older records of its window; under 2 minutes old it also wins a tie with a later record of the
        // same value, so the row keeps "실시간".
        int Fresh(TokenRateLimit limit) => limit.Live && (now - limit.RecordedAt).TotalSeconds < LiveLimits.LiveFor ? 1 : 0;
        var windows = limits.Where(limit => limit.ResetsAt is not null).GroupBy(limit => limit.WindowMinutes).Select(group =>
        {
            var newest = group.Max(limit => limit.ResetsAt!.Value);
            var window = group.Where(limit => Math.Abs(Seconds(limit.ResetsAt!.Value, newest)) <= 60).ToList();
            if (window.Where(limit => limit.Live).Select(limit => (DateTimeOffset?)limit.RecordedAt).Max() is { } polled)
                window = window.Where(limit => limit.RecordedAt >= polled).ToList();
            // An equal value goes to the newer record, so the source named beside the age is the one that recorded it.
            var top = window.MaxBy(limit => (limit.UsedPercent, Fresh(limit), limit.RecordedAt))!;
            return new UsageLimitSummary(top.UsedPercent, top.WindowMinutes, top.ResetsAt, top.Live ? top.RecordedAt : window.Max(limit => limit.RecordedAt))
                { Live = top.Live, RecordedBy = top.RecordedBy };
        }).ToList();
        var live = windows.Where(window => window.ResetsAt > now).ToList();
        if (live.Count == 0) return windows.MaxBy(window => (window.ResetsAt, window.WindowMinutes ?? 0));
        var shown = live.MaxBy(window => (window.UsedPercent, window.WindowMinutes ?? 0))!;
        // The other live window (the 5-hour one beside the weekly one) gets its own compact row, like Claude's.
        var other = live.Where(window => window.WindowMinutes != shown.WindowMinutes && window.WindowMinutes is not null).MaxBy(window => window.UsedPercent);
        return other is { WindowMinutes: { } minutes, ResetsAt: { } resets }
            ? shown with { Other = new UsageLimitSummary.OtherWindow(other.UsedPercent, minutes, resets)
                { RecordedAt = other.RecordedAt, Live = other.Live, RecordedBy = other.RecordedBy } }
            : shown;
    }

    /// Claude's two windows reduced like Codex's: the higher use among windows that have not reset (a tie goes to the
    /// longer window), the other one drawn as its own row; when both have reset, the latest reset reads "초기화됨" for a day.
    public static UsageLimitSummary? ClaudeUsageLimit(ClaudeUsageLimits limits, DateTimeOffset now)
    {
        List<(ClaudeLimitWindow Window, int Minutes)> windows = [];
        if (limits.FiveHour is { } fiveHour) windows.Add((fiveHour, 300));
        if (limits.SevenDay is { } sevenDay) windows.Add((sevenDay, 10_080));
        if (windows.Count == 0) return null;
        // Without a reset time (the desktop app), one full window after the record, as `UsageLimitSummary.ResetDate`.
        static DateTimeOffset Reset((ClaudeLimitWindow Window, int Minutes) pair) => pair.Window.ResetsAt ?? pair.Window.ReceivedAt.AddMinutes(pair.Minutes);
        var live = windows.Where(pair => Reset(pair) > now).ToList();
        var top = live.Count > 0 ? live.MaxBy(pair => (pair.Window.UsedPercent, pair.Minutes)) : windows.MaxBy(Reset);
        var other = live.Where(pair => pair.Minutes != top.Minutes)
            .Select(pair => pair.Window.ResetsAt is { } at ? new UsageLimitSummary.OtherWindow(pair.Window.UsedPercent, pair.Minutes, at) : null)
            .FirstOrDefault();
        return new UsageLimitSummary(top.Window.UsedPercent, top.Minutes, top.Window.ResetsAt, top.Window.ReceivedAt)
        { Source = TokenSource.Claude, Other = other, Live = top.Window.Live, RecordedBy = top.Window.Live ? null : top.Window.RecordedBy };
    }

    /// Select accounts before reducing windows; unidentified data never fills an identified account.
    public static IReadOnlyList<UsageLimitSummary> UsageLimits(IReadOnlyList<TokenReading> tokens,
        IReadOnlyList<TokenRateLimit> codexReads, IReadOnlyDictionary<string, ClaudeUsageLimits> claudeLimits,
        IReadOnlyDictionary<TokenSource, LimitAccount> defaults,
        IReadOnlyDictionary<TokenSource, IReadOnlyList<LimitAccount>> known, DateTimeOffset now)
    {
        List<UsageLimitSummary> result = [];
        // A post-switch session can still carry a cached limit from before its account attribution.
        var codexWindows = tokens.Where(token => token.Source == TokenSource.Codex && !IsTelemetry(token))
            .Select(token => token.RateLimit).OfType<TokenRateLimit>().Concat(codexReads).ToList();
        foreach (var provider in new[] { TokenSource.Codex, TokenSource.Claude })
        {
            var sessions = tokens.Where(token => token.LimitProvider == provider && !IsTelemetry(token)).ToList();
            var accounts = new HashSet<LimitAccount>(known.GetValueOrDefault(provider) ?? []);
            accounts.UnionWith(sessions.Select(token => token.LimitAccount).OfType<LimitAccount>());
            if (defaults.TryGetValue(provider, out var defaultAccount)) accounts.Add(defaultAccount);
            if (provider == TokenSource.Codex) accounts.UnionWith(codexWindows.Select(read => read.Account).OfType<LimitAccount>());
            var orderedAccounts = accounts.OrderBy(account => account.Key, StringComparer.Ordinal).ToList();
            var hashes = orderedAccounts.Select(account => account.StorageKey).ToHashSet(StringComparer.Ordinal);
            if (provider == TokenSource.Claude) hashes.UnionWith(claudeLimits.Keys.Where(key => key != "legacy"));
            var showLabels = hashes.Count >= 2;
            UsageLimitSummary? Summary(LimitAccount? account)
            {
                var value = provider == TokenSource.Codex
                    ? UsageLimit([], now, codexWindows.Where(read => read.Account == account).ToList())
                    : claudeLimits.TryGetValue(account?.StorageKey ?? "legacy", out var limits) ? ClaudeUsageLimit(limits, now) : null;
                if (value is null || !value.IsShown(now)) return null;
                string? label = null;
                if (showLabels && account is not null)
                {
                    label = account.Label;
                    var duplicates = orderedAccounts.Where(other => other.Label == account.Label).ToList();
                    if (duplicates.Count > 1)
                    {
                        var organization = account.OrganizationName ?? orderedAccounts.FirstOrDefault(other => other == account)?.OrganizationName;
                        if (organization is not null && duplicates.Count(other => other.OrganizationName == organization) == 1)
                            label += " · " + organization;
                        else
                        {
                            static string Suffix(string id) => id.Length > 4 ? id[^4..] : id;
                            label += " · …" + Suffix(account.Id);
                            if (duplicates.Count(other => Suffix(other.Id) == Suffix(account.Id)) > 1)
                                label += " · " + account.StorageKey[..6];
                        }
                    }
                }
                else if (showLabels) label = Loc("계정 미확인", "Unknown account");
                return value with { Account = account, AccountLabel = label };
            }
            var runningAccounts = sessions.Where(token => DisplayState(token, now).IsRunning)
                .Select(token => token.LimitAccount).OfType<LimitAccount>().ToHashSet();
            if (runningAccounts.Count > 0)
            {
                result.AddRange(runningAccounts.Select(Summary).OfType<UsageLimitSummary>()
                    .OrderByDescending(value => value.UsedPercent).ThenBy(value => value.Account?.Key ?? "", StringComparer.Ordinal));
            }
            else
            {
                var recent = sessions.OrderByDescending(token => token.LastActivity ?? DateTimeOffset.MinValue)
                    .ThenBy(token => token.Id, StringComparer.Ordinal).FirstOrDefault();
                var value = recent?.LimitAccount is { } recentAccount ? Summary(recentAccount) : null;
                value ??= defaultAccount is not null ? Summary(defaultAccount) : null;
                value ??= Summary(null);
                if (value is not null) result.Add(value);
            }
        }
        return result;
    }

    /// The flow card's "지금 속도": the newest measurement under 2 minutes old among visible live rows (leads and
    /// subagents), on the row's current model and from a client not waiting for a restart; one session's own value,
    /// never summed or averaged. Without one it is "—" while a turn is in progress, and null while sessions only wait for
    /// the person or a log, or nothing runs.
    public static SpeedHeadline? Headline(SessionListModel list, DateTimeOffset now, IReadOnlySet<TokenSource> restart)
    {
        var rows = SpeedRows(list);
        if (CurrentSpeed(list, now, restart) is not { } newest)
        {
            if (!rows.Any(row => row.State.ExpectsSpeed)) return null;
            var sources = Sources.Where(source => rows.Any(row => row.Reading.Source == source)).ToList();
            var waiting = sources.Where(restart.Contains).ToList();
            var names = string.Join(Loc("·", " and "), waiting.Select(source => source.Title));
            // A fresh measurement left out only for its model says so, rather than that none arrived.
            var previous = Measured(rows, now, restart, current: false).Select(item => item.Measurement).MaxBy(measurement => measurement.At);
            var reason = previous is not null
                ? Loc($"최근 실측은 이전 모델{(previous.Model is { } k ? $"({k})" : "")} 기준이라 지금 속도로 쓰지 않습니다",
                      $"The latest measurement is from the previous model{(previous.Model is { } e ? $" ({e})" : "")}, so it isn't used as the current speed")
                : Loc("진행 중인 세션의 최근 2분 실측 없음 · 로그 시각으로 추정하지 않습니다",
                      "No measurement from active sessions in the last 2 min · not estimated from log times");
            var help = waiting.Count == sources.Count
                ? Loc($"실측 연결됨 · {names}를 새로 실행하면 속도가 표시됩니다", $"Telemetry connected · restart {names} to show speed")
                : reason + (waiting.Count == 0 ? "" : Loc($"\n{names}를 새로 실행하면 속도가 표시됩니다", $"\nRestart {names} to show speed"));
            return new SpeedHeadline("—", null, null, help, Loc("속도 실측 없음", "No measured speed"));
        }
        var reading = newest.Row.Reading;
        var project = reading.Project ?? Loc("프로젝트 미확인", "Unknown project");
        // A subagent's row is named by its agent, so the headline keeps the project there.
        var label = reading.IsSubagent ? project : RowTitle(reading);
        var session = string.Join(" · ", new[] { reading.IsSubagent ? null : reading.Title, project,
                                                 reading.IsSubagent ? Loc("하위 ", "subagent ") + ChildName(reading) : null,
                                                 reading.ClientTitle + (reading.Model is { } model ? " " + model : "") }.OfType<string>());
        var value = Format.Tps(newest.Rate);
        var age = HelpAge(newest.Measurement.At, now);
        var kind = SpokenKind(newest.Measurement.Kind);
        return new SpeedHeadline(value, newest.Measurement.Kind?.Title ?? "tok/s", label,
            Loc($"{session} · 측정 {age}\n{newest.Measurement.Details}\n가장 최근 실측 한 건이며 세션끼리 합치거나 평균내지 않습니다",
                $"{session} · measured {age}\n{newest.Measurement.Details}\nThe single latest measurement; sessions are never summed or averaged"),
            Loc($"{kind} 초당 {value} 토큰, {label}", $"{kind} {value} tokens per second, {label}"));
    }

    /// Visible live rows: leads and subagents.
    static List<SessionRowItem> SpeedRows(SessionListModel list)
    {
        var rows = new List<SessionRowItem>();
        foreach (var block in list.Blocks)
        {
            if (block.Lead.Kind == SessionRowKind.Live) rows.Add(block.Lead);
            rows.AddRange(block.Children.Where(child => child.State.IsLive));
        }
        return rows;
    }

    /// Measured rows from clients not waiting for a restart, under 2 minutes old; `current` keeps those on the row's model.
    static IEnumerable<(SessionRowItem Row, TokenSpeedMeasurement Measurement, double Rate)> Measured(IEnumerable<SessionRowItem> rows,
        DateTimeOffset now, IReadOnlySet<TokenSource> restart, bool current)
    {
        foreach (var row in rows)
            if (!restart.Contains(row.Reading.Source) && row.Reading.SpeedMeasurement is { } measurement
                && measurement.TokensPerSecond is { } rate && (measurement.Model == row.Reading.Model) == current
                && Seconds(now, measurement.At) is >= -5 and < 120) yield return (row, measurement, rate);
    }

    /// "지금 속도"'s pick (`Headline`): the newest fresh measurement.
    public static (SessionRowItem Row, TokenSpeedMeasurement Measurement, double Rate)? CurrentSpeed(SessionListModel list, DateTimeOffset now,
        IReadOnlySet<TokenSource> restart) =>
        Measured(SpeedRows(list), now, restart, current: true).OrderByDescending(item => item.Measurement.At)
            .ThenBy(item => item.Row.Id, StringComparer.Ordinal).Select(item => ((SessionRowItem, TokenSpeedMeasurement, double)?)item).FirstOrDefault();

    /// The widget's opt-in "평균 속도": the arithmetic mean of every client's fresh per-session rates (`CurrentSpeed`'s rule) and
    /// the clients they came from, null without one. Only measured rates are averaged; nothing is estimated.
    public static AverageSpeed? Average(SessionListModel list, DateTimeOffset now, IReadOnlySet<TokenSource> restart)
    {
        var fresh = Measured(SpeedRows(list), now, restart, current: true).ToList();
        if (fresh.Count == 0) return null;
        var sources = fresh.GroupBy(item => item.Row.Reading.Source).Select(group => (Source: group.Key, Rate: group.Average(item => item.Rate)))
            .OrderByDescending(item => item.Rate).ThenBy(item => item.Source).Select(item => item.Source).ToList();
        return new AverageSpeed(fresh.Average(item => item.Rate), sources);
    }

    public static string SpokenKind(TokenRateKind? kind) => kind switch
    {
        TokenRateKind.ServerGeneration => Loc("생성 속도", "Generation speed"),
        TokenRateKind.ServerAggregate => Loc("모델 평균 속도", "Model average speed"),
        _ => Loc("요청 처리 속도", "Request processing rate"),
    };

    /// Only exact-identity telemetry; never a speed derived from log timing.
    public static SpeedSlot Speed(TokenReading reading, DateTimeOffset now, bool restartNeeded = false)
    {
        if (reading.SpeedMeasurement is not { } measurement || measurement.TokensPerSecond is not { } rate)
        {
            var help = restartNeeded
                ? Loc($"실측 연결됨 · {reading.Source.Title}를 새로 실행하면 속도가 표시됩니다", $"Telemetry connected · restart {reading.Source.Title} to show speed")
                : Loc("속도 실측 없음 · 로그 시각으로 추정하지 않습니다", "No measured speed · not estimated from log times");
            return new SpeedSlot(null, "—", null, false, help, Loc("속도 실측 없음", "No measured speed"));
        }
        var kind = measurement.Kind?.Title ?? "tok/s";
        var spoken = Loc($"{SpokenKind(measurement.Kind)} 초당 {Format.Tps(rate)} 토큰", $"{SpokenKind(measurement.Kind)} {Format.Tps(rate)} tokens per second");
        if (measurement.Model != reading.Model)
        {
            var model = measurement.Model ?? Loc("미확인", "unknown");
            var measured = HelpAge(measurement.At, now);
            return new SpeedSlot(Loc("이전", "previous"), Format.Tps(rate), kind, false,
                                 Loc($"이전 실측 모델 {model} · 측정 {measured}", $"Previously measured model {model} · measured {measured}"),
                                 Loc("이전 모델 ", "Previous model, ") + spoken);
        }
        var age = Seconds(now, measurement.At);
        return new SpeedSlot(null, Format.Tps(rate), kind, age >= -5 && age < 120, measurement.Details, spoken);
    }

    /// A live row's speed cell: none without a speed column or while its client waits for a restart, and "—" only where
    /// a speed is expected (working, tool, API retry).
    public static SpeedSlot? SpeedCell(TokenReading reading, SessionDisplayState state, DateTimeOffset now, bool showsColumn, IReadOnlySet<TokenSource> restart)
    {
        if (!showsColumn || restart.Contains(reading.Source)) return null;
        var slot = Speed(reading, now);
        return slot.Known || state.ExpectsSpeed ? slot : null;
    }

    // Header, flow caption, footer

    /// Seconds of quiet after which the header head sleeps.
    public const double SleepAfter = 600;

    /// The header sentence (H-2) and head echo (H-3) from the shared counts. `quietSince` is the tray cat's quiet reference
    /// (`RunnerDirector.QuietSince`); without it the newest activity is used. `spoken` spells English spans out.
    public static HeaderStatus Header(SessionCounts counts, bool loading, DateTimeOffset now, DateTimeOffset? quietSince = null, bool spoken = false)
    {
        if (loading)
            return new HeaderStatus(Loc("기록 확인 중", "Reading records"), "", null, Loc("코딩 에이전트 기록을 읽고 있습니다", "Reading coding agent records"))
            { Muted = true };
        var tools = Enum.GetValues<ToolCategory>().Where(category => counts.ToolCategories.GetValueOrDefault(category) > 0)
            .Select(category => $"{ToolTitle(category)} {counts.ToolCategories[category]}").ToList();
        var breakdown = tools.Count == 0 ? "" : Loc("\n하위 에이전트 포함 ", "\nIncluding subagents: ") + string.Join(" · ", tools);
        var others = counts.RunningGroups - counts.Input;
        if (counts.Input > 0)
        {
            var (plans, n) = (counts.InputPlansOnly, counts.Input);
            return new HeaderStatus(
                Loc((plans ? "계획 승인 대기 " : "입력 필요 ") + $"{n}개",
                    plans ? $"{Plural(n, "plan")} awaiting approval" : $"{Plural(n, "session")} {(n == 1 ? "needs" : "need")} input"),
                others > 0 ? Loc($" · 진행 {others}개", $" · {others} working")
                    : plans ? Loc(" · 승인하면 계속됩니다", " · approve to continue") : Loc(" · 답변하면 계속됩니다", " · reply to continue"),
                StateGlyphKind.Input,
                Loc("질문이나 계획 승인을 기다립니다. 권한 확인 요청은 로그에 남지 않아 표시하지 않습니다",
                    "Waiting for an answer or plan approval. Permission prompts aren't logged, so they aren't shown") + breakdown)
            { Head = RunnerHead.Alert };
        }
        if (counts.Retrying > 0)
            return new HeaderStatus(Loc($"API 재시도 {counts.Retrying}개", $"{Plural(counts.Retrying, "session")} retrying"),
                                    counts.Retry is { } retry ? " · " + RetryText(retry, now, spoken: spoken) : "", StateGlyphKind.Retry,
                                    Loc("API 재시도 기록 · 오류 내용은 저장하지 않습니다", "API retry recorded · error details aren't stored") + breakdown);
        if (counts.Tool + counts.Working > 0)
        {
            var parts = new[]
            {
                counts.ToolMembers > 0 ? Loc($"도구 실행 {counts.ToolMembers}", Plural(counts.ToolMembers, "tool")) : null,
                counts.RunningSubagents > 0 ? Loc($"하위 {counts.RunningSubagents}", Plural(counts.RunningSubagents, "subagent")) : null,
            }.OfType<string>();
            return new HeaderStatus(Loc($"세션 {counts.RunningGroups}개 진행 중", $"{Plural(counts.RunningGroups, "session")} working"),
                                    string.Concat(parts.Select(part => " · " + part)),
                                    counts.Tool > 0 ? StateGlyphKind.Tool : StateGlyphKind.Working,
                                    Loc($"진행 중인 세션 {counts.RunningGroups}개 · 하위 에이전트 {counts.RunningSubagents}개 실행 중",
                                        $"{Plural(counts.RunningGroups, "active session")} · {Plural(counts.RunningSubagents, "subagent")} running") + breakdown);
        }
        if (counts.Waiting > 0)
        {
            var minutes = counts.WaitingSince is { } since ? Math.Max(1, (int)Seconds(now, since) / 60) : 1;
            return new HeaderStatus(Loc($"로그 대기 {counts.Waiting}개", $"{Plural(counts.Waiting, "session")} waiting for log"),
                                    Loc($" · {minutes}분째 새 기록 없음", $" · no record for {Format.Span(minutes, Format.TimeUnit.Minute, spoken)}"),
                                    StateGlyphKind.Waiting,
                                    Loc("턴이 열려 있지만 새 기록이 없습니다. 도구나 모델 응답을 기다리는 중일 수 있습니다",
                                        "The turn is open but nothing new has been recorded. It may be waiting for a tool or the model"));
        }
        var quiet = (quietSince ?? counts.NewestActivity) is not { } reference || Seconds(now, reference) >= SleepAfter;
        return new HeaderStatus(Loc("진행 중인 세션 없음", "No active sessions"),
                                counts.NewestActivity is { } newest ? Loc(" · 마지막 활동 ", " · last activity ") + HelpAge(newest, now, spoken) : "",
                                null, Loc("진행 중인 코딩 에이전트 세션이 없습니다", "No active coding agent sessions"))
        { Head = quiet ? RunnerHead.Sleep : RunnerHead.Normal };
    }

    /// The flow card's per-client split, widest first: "Claude Code 6.6k · Codex 1.2k · OpenCode 300", then the smallest
    /// folding into " · +N more" down to the largest alone; one client is its name only (never the hero number again). The card
    /// shows the first candidate that fits beside "지금 속도", so four or more clients never spill past it.
    public static IReadOnlyList<string> ProviderSplits(IReadOnlyDictionary<TokenSource, int> byProvider)
    {
        var parts = Enum.GetValues<TokenSource>().Select(source => (source, value: byProvider.GetValueOrDefault(source)))
            .Where(p => p.value > 0).OrderByDescending(p => p.value).ToList();
        if (parts.Count < 2) return [parts.Count == 0 ? "" : parts[0].source.Title];
        return Enumerable.Range(1, parts.Count).Reverse()
            .Select(shown => string.Join(" · ", parts.Take(shown).Select(p => $"{p.source.Title} {Format.CompactTokens(p.value)}"))
                + (shown < parts.Count ? Loc($" · 외 {parts.Count - shown}", $" · +{parts.Count - shown} more") : ""))
            .ToList();
    }

    /// The caption over the last-record value (F-2): why nothing new is recorded, after 30 s without a record. A turn waiting
    /// for the person keeps the base caption: the header already says so.
    public static FlowCaption Caption(SessionCounts counts, DateTimeOffset? last, DateTimeOffset now, bool spoken = false)
    {
        var @base = new FlowCaption(LastRecordCaption, Loc("최근 5분 안에 로그에 기록된 마지막 출력입니다", "The latest output recorded in the logs within the last 5 min"));
        if (counts.LiveGroups <= 0 || counts.Input > 0) return @base;
        if (last is { } at && Seconds(now, at) <= 30) return @base;
        var help = Loc("응답이 끝나면 토큰이 기록됩니다. 코딩 에이전트는 응답이나 메시지가 끝날 때 기록하므로 생성 중인 토큰은 아직 포함되지 않습니다",
                       "Tokens are recorded when a response ends. Coding agents record at the end of a response or message, so tokens still being generated aren't included yet");
        if (counts.Retrying > 0)
        {
            var text = counts.Retry is { } retry
                ? retry.NetworkDown ? Loc("API 재시도 · 네트워크 끊김", "API retry · network down") : RetryText(retry, now, api: true, spoken: spoken)
                : Loc("API 재시도", "API retry");
            return new FlowCaption(text, help) { Glyph = StateGlyphKind.Retry, Emphasized = true };
        }
        if (counts.Tool > 0)
        {
            var tool = ToolTitle(counts.LeadingToolCategory);
            return new FlowCaption(Loc($"{tool} 중 · 응답 후 기록", $"{tool} · logged after reply"), help);
        }
        if (counts.Working > 0) return new FlowCaption(Loc("진행 중 · 응답 후 기록", "Working · logged after reply"), help);
        var minutes = counts.WaitingSince is { } since ? Math.Max(1, (int)Seconds(now, since) / 60) : 1;
        return new FlowCaption(Loc($"로그 대기 · {minutes}분째 기록 없음", $"Waiting for log · no record for {Format.Span(minutes, Format.TimeUnit.Minute, spoken)}"), help);
    }

    /// Cause-specific copy from the collector state, the setup note and pending or expired restarts.
    /// `status` is the collector's own sentence, used only as help text.
    public static TelemetryNotice? Notice(TelemetryCollectorState state, string? note, IReadOnlySet<TokenSource> restart, string? status = null,
                                          TelemetrySetupFailure? failure = null, IReadOnlySet<TokenSource>? expired = null)
    {
        var open = Loc("\n누르면 설정을 엽니다", "\nClick to open Settings");
        switch (state)
        {
            case TelemetryCollectorState.BusyTokenCat:
                return new TelemetryNotice(TelemetryNoticeKind.Busy, Loc("실측 꺼짐 · 다른 TokenCat", "Telemetry off · another TokenCat"),
                    Loc("다른 TokenCat이 이미 실측을 수집하고 있어 이 TokenCat은 실측을 받지 않습니다. 하나만 실행하세요.",
                        "Another TokenCat is already collecting telemetry, so this one doesn't receive it. Run only one.") + open);
            case TelemetryCollectorState.BusyOtherApp:
                return new TelemetryNotice(TelemetryNoticeKind.PortBusy, Loc("실측 꺼짐 · 포트 사용 중", "Telemetry off · port in use"),
                    Loc($"로컬 실측 수집기가 127.0.0.1:{TelemetrySetup.Port} 포트를 열지 못했습니다. 다른 앱이 포트를 쓰고 있을 수 있습니다.",
                        $"The local telemetry collector couldn't open port 127.0.0.1:{TelemetrySetup.Port}. Another app may be using it.") + open);
            case TelemetryCollectorState.Failed:
                return new TelemetryNotice(TelemetryNoticeKind.Collector, Loc("실측 꺼짐 · 수집기 오류", "Telemetry off · collector error"), (status ?? state.Status) + open);
            case TelemetryCollectorState.Stopped:
                return new TelemetryNotice(TelemetryNoticeKind.Off, Loc("실측 꺼짐", "Telemetry off"), (status ?? state.Status) + open);
        }
        if (note is not null)
        {
            var conflict = failure is TelemetrySetupFailure.Conflict;
            return new TelemetryNotice(conflict ? TelemetryNoticeKind.Conflict : TelemetryNoticeKind.Failed,
                conflict ? Loc("실측 꺼짐 · 설정 충돌", "Telemetry off · config conflict") : Loc("실측 꺼짐 · 연결 실패", "Telemetry off · connection failed"),
                note + open);
        }
        if (expired is { Count: > 0 })
            return new TelemetryNotice(TelemetryNoticeKind.Expired, Loc("실측 미수신 · 확인 필요", "No telemetry · check needed"),
                Loc($"{Names(expired)}: 이 버전에서 실측을 받지 못했습니다. 새로 실행한 뒤에도 그대로면 설정에서 연결 상태를 확인하세요.",
                    $"{Names(expired)}: no telemetry received with this version. If it's still missing after a restart, check the connection in Settings.") + open);
        if (restart.Count == 0) return null;
        return new TelemetryNotice(TelemetryNoticeKind.Restart, Loc($"{Names(restart)} 재시작 후 속도 표시", $"Restart {Names(restart)} for speed"),
            Loc($"{Names(restart)}를 새로 실행하면 속도가 표시됩니다. 진행 중인 작업은 재시작하지 않습니다.",
                $"Restart {Names(restart)} to show speed. TokenCat doesn't restart running work.") + open);
    }

    /// One footer item: collection delay first, then the telemetry notice, then "실시간".
    public static FooterStatus Footer(bool loading, int tokenDelay, int systemDelay, TelemetryNotice? notice)
    {
        if (loading) return new FooterStatus(FooterStatusKind.Loading, Loc("준비 중", "Preparing"));
        if (tokenDelay > 3)
            return new FooterStatus(FooterStatusKind.AiDelay, Loc($"AI 수집 지연 {tokenDelay}초", $"AI collection delayed {Format.Span(tokenDelay, Format.TimeUnit.Second)}"));
        if (systemDelay > 3)
            return new FooterStatus(FooterStatusKind.SystemDelay,
                Loc($"시스템 수집 지연 {systemDelay}초", $"System collection delayed {Format.Span(systemDelay, Format.TimeUnit.Second)}"));
        if (notice is not null) return new FooterStatus(FooterStatusKind.Notice, notice.Text);
        return new FooterStatus(FooterStatusKind.Live, Loc("실시간", "Live"));
    }

    /// "실측 수신: Codex 기록 없음 · Claude Code 2분 전", minute-granular for a stable tooltip. Gemini CLI and Qwen Code join
    /// once they have sent something.
    public static string TelemetryReceipt(IReadOnlyDictionary<TokenSource, DateTimeOffset> lastReceived, DateTimeOffset now) =>
        Loc("실측 수신: ", "Telemetry received: ")
        + string.Join(" · ", TokenSource.TelemetryClients.Where(source => TokenSource.DefaultClients.Contains(source) || lastReceived.ContainsKey(source))
            .Select(source => $"{source.Title} {HelpAge(lastReceived.TryGetValue(source, out var at) ? at : null, now)}"));

    /// Expanded-list date captions from the model clock.
    public static string DaySection(DateTimeOffset date, DateTimeOffset now, DayCalendar calendar)
    {
        var day = TimeZoneInfo.ConvertTime(date, calendar.Zone).Date;
        var today = TimeZoneInfo.ConvertTime(now, calendar.Zone).Date;
        if (day == today || date > now) return Loc("오늘", "Today");
        if (day == today.AddDays(-1)) return Loc("어제", "Yesterday");
        DateTime WeekStart(DateTime value) => value.AddDays(-(((int)value.DayOfWeek - (int)calendar.FirstDay + 7) % 7));
        if (WeekStart(day) == WeekStart(today)) return Loc("이번 주", "This week");
        return OlderSection;
    }

    public static string OlderSection => Loc("이전", "Earlier");

    // Detail and row actions

    /// The inline detail under a clicked row (S-6). Metadata only; nothing from the conversation.
    public static List<DetailItem> DetailItems(TokenReading reading, SessionDisplayState state)
    {
        var unknown = Loc("미확인", "Unknown");
        List<DetailItem> items = [new(Loc("세션 ID", "Session ID"), reading.SessionID ?? unknown, reading.SessionID)];
        if (reading.IsSubagent) items.Add(new(Loc("에이전트", "Agent"), reading.AgentID ?? unknown, reading.AgentID));
        if (reading.Model is { } model) items.Add(new(Loc("모델", "Model"), model + (EffortLabel(reading) is { } effort ? $" · {effort}" : "")));
        if (state == SessionDisplayState.Tool)
            items.Add(new(Loc("도구", "Tool"), ToolTitle(reading.ToolCategory) + (reading.ToolName is { } name ? $" · {name}" : "")));
        if (reading.LastOutputTokens is { } output)
        {
            var seconds = reading.LastTurnDurationSeconds is { } value && double.IsFinite(value) && value >= 0 ? Round(value) : (int?)null;
            items.Add(new(Loc("마지막 완료 턴", "Last turn"), $"{Format.Tokens(output)} tok" + (seconds is { } s ? $" · {Clock(s)}" : "")));
        }
        var codex = reading.Source == TokenSource.Codex;
        items.Add(new(Loc("기록 시점", "Recorded"),
                      Loc($"{reading.ClientTitle}는 {(codex ? "응답" : "메시지")} 완료 시 기록", $"When a {reading.ClientTitle} {(codex ? "response" : "message")} ends")));
        return items;
    }

    /// 8 + 15 per line + 8, plus the 0.5 pt rule above it; the action line adds 6 + 20.
    public static double DetailHeight(TokenReading reading, SessionDisplayState state) =>
        16 + 15 * DetailItems(reading, state).Count + 0.5 + (DetailActions(reading).Count > 0 ? 26 : 0);

    /// The inline detail's buttons: the resume command, then File Explorer on the project folder (else the log file).
    public static List<RowAction> DetailActions(TokenReading reading, string? home = null)
    {
        var actions = new List<RowAction>();
        if (ResumeCommand(reading) is { } command) actions.Add(new(Loc("재개 명령 복사", "Copy Resume Command"), "terminal", Copy: command));
        var target = reading.ProjectPath is { } path && IsWindowsAbsolute(path) ? path : LogFilePath(reading, home ?? AppPaths.Home);
        if (target is not null) actions.Add(new(Loc("탐색기에서 보기", "Show in File Explorer"), "folder", Reveal: target));
        return actions;
    }

    /// The log file the reading came from: its id is "<source>:<path relative to home>" with "/" separators (rule 7), and a
    /// log holding several sessions (OpenCode's database) appends "#<session>". JSONL logs, JSON snapshots (Amp, Cline,
    /// legacy Gemini) and databases are revealed.
    public static string? LogFilePath(TokenReading reading, string home)
    {
        var colon = reading.Id.IndexOf(':');
        if (IsTelemetry(reading) || colon < 0) return null;
        var id = reading.Id[(colon + 1)..];
        var fragment = id.LastIndexOf('#');
        var path = fragment >= 0 ? id[..fragment] : id;
        if (path.Length == 0 || (fragment < 0 && !new[] { ".jsonl", ".json", ".db" }.Any(extension => path.EndsWith(extension, StringComparison.Ordinal))))
            return null;
        return Path.IsPathFullyQualified(path) ? path : Path.Combine(home, path.Replace('/', Path.DirectorySeparatorChar));
    }

    /// A Windows folder from a log's `cwd`: drive-absolute ("C:\…", "C:/…") or UNC ("\\server\share").
    static bool IsWindowsAbsolute(string path) =>
        path.Length >= 3 && char.IsAsciiLetter(path[0]) && path[1] == ':' && path[2] is '\\' or '/' || path.StartsWith(@"\\", StringComparison.Ordinal);

    /// PowerShell single quoting: `'` and its typographic forms (which PowerShell also reads as quotes) are doubled.
    public static string ShellQuote(string text) =>
        "'" + string.Concat(text.Select(c => c is '\'' or '\u2018' or '\u2019' or '\u201A' or '\u201B' ? $"{c}{c}" : c.ToString())) + "'";

    /// "cd -LiteralPath '<project>'; <client resume command> <id>" (e.g. "claude --resume <id>") for PowerShell (5.1 has no `&&`); null for
    /// subagents or without an ID or folder. Control characters (keystrokes on paste) and cmd.exe's metacharacters (a paste
    /// into cmd would run them) are refused, as is a client without a known resume command (a row of another product,
    /// `ClientName`, never gets its source's command).
    public static string? ResumeCommand(TokenReading reading)
    {
        static bool Unsafe(string text) => text.Any(c => char.IsControl(c) || c is '&' or '|' or '<' or '>' or '^' or '%');
        if (reading.Source.ResumeCommand is not { } resume || reading.ClientName is not null || reading.IsSubagent || IsTelemetry(reading)
            || reading.SessionID is not { Length: > 0 } session
            || reading.ProjectPath is not { } path || !IsWindowsAbsolute(path) || Unsafe(path) || Unsafe(session)) return null;
        var plain = session.All(c => char.IsAsciiLetterOrDigit(c) || c is '-' or '_' or '.');
        var id = plain ? session : ShellQuote(session);
        return $"cd -LiteralPath {ShellQuote(path)}; {resume} {id}";
    }

    /// Copies first, then File Explorer reveals.
    public static List<RowAction> RowActions(TokenReading reading, string? home = null)
    {
        var actions = new List<RowAction>();
        if (reading.SessionID is { Length: > 0 } session) actions.Add(new(Loc("세션 ID 복사", "Copy Session ID"), "doc.on.doc", Copy: session));
        if (reading.AgentID is { Length: > 0 } agent) actions.Add(new(Loc("에이전트 ID 복사", "Copy Agent ID"), "doc.on.doc", Copy: agent));
        if (ResumeCommand(reading) is { } command) actions.Add(new(Loc("재개 명령 복사", "Copy Resume Command"), "terminal", Copy: command));
        if (reading.ProjectPath is { } path && IsWindowsAbsolute(path))
            actions.Add(new(Loc("프로젝트 폴더 탐색기에서 보기", "Show Project Folder in File Explorer"), "folder", Reveal: path));
        if (LogFilePath(reading, home ?? AppPaths.Home) is { } log)
            actions.Add(new(Loc("기록 파일 탐색기에서 보기", "Show Log File in File Explorer"), "doc.text.magnifyingglass", Reveal: log));
        return actions;
    }
}
