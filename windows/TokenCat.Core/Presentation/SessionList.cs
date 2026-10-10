using static TokenCat.Lang;

namespace TokenCat;

// SessionPresentation.swift's list model (SessionRowItem, SessionBlock, SessionListEntry, SessionListModel): computed once per
// publish; views never re-sort. Heights are the mac's points, used as WPF DIPs.

public enum SessionRowKind { Live, Idle, Measurement, Child }

public sealed record SessionRowItem(TokenReading Reading, SessionDisplayState State, SessionRowKind Kind)
{
    public const double LiveDetailHeight = 58;
    /// Live rows show line 3 only when it holds the turn's last record, context or a measured speed.
    public bool ShowsDetail { get; init; } = true;
    public string Id => Reading.Id;
    public double Height => Kind switch
    {
        SessionRowKind.Live => ShowsDetail ? LiveDetailHeight : 44,
        SessionRowKind.Child => 24,
        _ => 28,
    };
}

public sealed record SessionBlock(SessionRowItem Lead, IReadOnlyList<SessionRowItem> Children, int ChildCount, SessionDisplayState State)
{
    /// Live children in the whole group, shown or not.
    public int RunningChildren { get; init; }
    public int WaitingChildren { get; init; }
    /// Children waiting for a log left out of the collapsed list; running children are never cut.
    public int MoreCount { get; init; }
    public string MoreText { get; init; } = "";
    public string MoreSpoken { get; init; } = "";
    /// Expanded list only: the date section of an unpinned block; captions are drawn where it changes.
    public string? Section { get; init; }
    public bool Older => Section == SessionPresentation.OlderSection;
    public string Id => Lead.Id;
    /// The "+N 하위" row's navigation id.
    public string MoreID => "more:" + Id;
    public double Height => Children.Sum(child => child.Height) + Lead.Height + (MoreCount > 0 ? SessionListModel.MoreHeight : 0);

    /// Tops of the rows inside the block, relative to the block.
    public IReadOnlyList<(double Top, double Height)> RowFrames
    {
        get
        {
            var frames = new List<(double Top, double Height)> { (0, Lead.Height) };
            var y = Lead.Height;
            foreach (var child in Children) { frames.Add((y, child.Height)); y += child.Height; }
            if (MoreCount > 0) frames.Add((y, SessionListModel.MoreHeight));
            return frames;
        }
    }
}

public abstract record SessionListEntry
{
    /// A full-width rule between blocks.
    public sealed record Divider(string Key) : SessionListEntry;
    /// `Rule` draws a rule above every caption but the first. `Anchor` is the following block's id, so a caption stays unique
    /// even when a frozen order repeats a section.
    public sealed record Caption(string Text, bool Rule, string Anchor) : SessionListEntry;
    public sealed record Block(SessionBlock Value) : SessionListEntry;
    /// "이전 기록 더 보기" with the folded block count.
    public sealed record Older(int Count) : SessionListEntry;
    /// The one list disclosure at the very end: "세션 N개 모두 보기", "하위 N개 더 보기" or "접기".
    public sealed record Toggle : SessionListEntry;

    public string Id => this switch
    {
        Divider divider => "divider:" + divider.Key,
        Caption caption => "caption:" + caption.Anchor,
        Block block => block.Value.Id,
        Toggle => SessionListModel.ToggleID,
        _ => SessionListModel.OlderID,
    };

    public double Height => this switch
    {
        Divider => SessionListModel.DividerHeight,
        Caption => SessionListModel.CaptionHeight,
        Block block => block.Value.Height,
        _ => SessionListModel.OlderHeight,
    };
}

/// Computed once per publish; views never re-sort.
public sealed record SessionListModel
{
    public const double MaxViewport = 312, DividerHeight = 1, CaptionHeight = 24;
    public const int CollapsedMinimum = 6, CollapsedChildren = 3;
    /// The "+N 하위" summary row.
    public const double MoreHeight = 24;
    /// "이전 기록 더 보기" and the list toggle.
    public const double OlderHeight = 28;
    public const string OlderID = "older", ToggleID = "toggle";

    /// The full list (every group, finished children, date captions) rather than the collapsed one.
    public bool Expanded { get; init; }

    public IReadOnlyList<SessionBlock> Blocks { get; init; } = [];
    public SessionCounts Counts { get; init; } = new();
    /// Top-level groups and children of shown groups not visible while collapsed.
    public int HiddenGroups { get; init; }
    public int HiddenChildren { get; init; }
    /// Hidden children not already offered by a group's "+N 하위" row (finished children of a collapsed group).
    int UnofferedChildren => HiddenChildren - Blocks.Sum(block => block.MoreCount);
    /// The list toggle shows while something is folded away that no "+N 하위" row offers, or to fold the expanded list again.
    public bool ShowsToggle => Expanded || HiddenGroups > 0 || UnofferedChildren > 0;
    public string ToggleText => Expanded ? Loc("접기", "Show less")
        : HiddenGroups > 0 ? Loc($"세션 {Counts.Groups}개 모두 보기", $"Show all {Plural(Counts.Groups, "session")}")
        : Loc($"하위 {UnofferedChildren}개 더 보기", $"Show {Plural(UnofferedChildren, "more subagent")}");
    public string ToggleHelp => Loc($"하위 에이전트 포함 {Counts.Readings}개 기록", $"{Plural(Counts.Readings, "record")} including subagents")
        + (Expanded || HiddenGroups == 0 ? "" : Loc($" · 접힌 세션 {HiddenGroups}개", $" · {Plural(HiddenGroups, "collapsed session")}"));
    public string ToggleSpoken => Expanded ? Loc("세션 목록 접기", "Collapse session list")
        : HiddenGroups > 0 ? Loc("세션 목록 모두 보기", "Show all sessions") : Loc("하위 에이전트 더 보기", "Show more subagents");
    /// Expanded only: blocks in the folded "이전" section.
    public int OlderCount { get; init; }
    /// With "이전" folded.
    public double ContentHeight { get; init; }
    public double OlderContentHeight { get; init; }
    /// Some visible live lead row has a measured speed from a client not waiting for a restart (S-3); otherwise no row has
    /// a speed cell. Child rows have no speed cell, so their measurements never open a column of "—".
    public bool ShowsSpeedColumn { get; init; }
    double FoldedViewport { get; init; }
    double OpenViewport { get; init; }

    public static SessionListModel Empty { get; } = new();

    public List<SessionListEntry> Entries(bool showOlder)
    {
        var entries = new List<SessionListEntry>();
        var folded = false;
        string? section = null;
        foreach (var block in Blocks)
        {
            if (block.Older && !showOlder)
            {
                if (!folded)
                {
                    if (entries.Count > 0) entries.Add(new SessionListEntry.Divider(OlderID));
                    entries.Add(new SessionListEntry.Older(OlderCount));
                    folded = true;
                }
                continue;
            }
            if (block.Section is { } next && next != section)
            {
                // Only a caption at the very top goes without a rule; one under a pinned live row keeps it.
                entries.Add(new SessionListEntry.Caption(next, entries.Count > 0, block.Id));
                section = next;
            }
            else if (entries.Count > 0) entries.Add(new SessionListEntry.Divider(block.Id));
            entries.Add(new SessionListEntry.Block(block));
        }
        if (ShowsToggle && entries.Count > 0)
        {
            entries.Add(new SessionListEntry.Divider(ToggleID));
            entries.Add(new SessionListEntry.Toggle());
        }
        return entries;
    }

    public double Height(bool showOlder) => OlderCount > 0 && showOlder ? OlderContentHeight : ContentHeight;
    public double Viewport(bool showOlder) => OlderCount > 0 && showOlder ? OpenViewport : FoldedViewport;

    /// Selectable rows in visual order (P-2): leads, children, "+N 하위", "이전 기록" and the toggle; captions and dividers are
    /// skipped.
    public List<string> Navigation(bool showOlder)
    {
        var ids = new List<string>();
        foreach (var entry in Entries(showOlder))
        {
            if (entry is SessionListEntry.Older or SessionListEntry.Toggle) ids.Add(entry.Id);
            if (entry is not SessionListEntry.Block { Value: var block }) continue;
            ids.Add(block.Id);
            ids.AddRange(block.Children.Select(child => child.Id));
            if (block.MoreCount > 0) ids.Add(block.MoreID);
        }
        return ids;
    }

    /// Projects on more than one visible top-level row; only those rows add a short ID. The folded "이전" part is not visible.
    public HashSet<string> SharedProjects(bool showOlder) =>
        Blocks.Where(block => (showOlder || !block.Older) && block.Lead.Kind != SessionRowKind.Measurement)
            .Select(block => block.Lead.Reading.Project).OfType<string>().Where(project => project.Length > 0)
            .GroupBy(project => project).Where(group => group.Count() > 1).Select(group => group.Key).ToHashSet();

    /// Where keyboard selection starts: the first row waiting for input, else the first retry, else the first row.
    public string? StartRow(bool showOlder)
    {
        var rows = Blocks.SelectMany(block => block.Children.Prepend(block.Lead)).ToList();
        var navigation = Navigation(showOlder);
        var visible = navigation.ToHashSet();
        foreach (var state in new[] { SessionDisplayState.Input, SessionDisplayState.Retrying })
            if (rows.FirstOrDefault(row => row.State == state && visible.Contains(row.Id)) is { } row) return row.Id;
        return navigation.FirstOrDefault();
    }

    /// The row item for a navigation id, if it is a session row.
    public SessionRowItem? Item(string id)
    {
        foreach (var block in Blocks)
        {
            if (block.Lead.Id == id) return block.Lead;
            if (block.Children.FirstOrDefault(child => child.Id == id) is { } child) return child;
        }
        return null;
    }

    /// The same blocks in a frozen order (S-8): known blocks keep their place, new ones go to the end.
    public SessionListModel Reordered(IReadOnlyList<string> order)
    {
        var rank = new Dictionary<string, int>();
        for (var i = 0; i < order.Count; i++) rank.TryAdd(order[i], i);
        return (this with { Blocks = Blocks.Select((block, offset) => (block, offset))
            .OrderBy(item => rank.GetValueOrDefault(item.block.Id, int.MaxValue)).ThenBy(item => item.offset)
            .Select(item => item.block).ToList() }).Measured();
    }

    SessionListModel Measured()
    {
        List<SessionListEntry> folded = Entries(showOlder: false), open = Entries(showOlder: true);
        return this with
        {
            ContentHeight = folded.Sum(entry => entry.Height), OlderContentHeight = open.Sum(entry => entry.Height),
            FoldedViewport = SnappedViewport(folded), OpenViewport = SnappedViewport(open),
        };
    }

    /// The cut lands at least 12pt inside a row and hides at least 6pt of it, so a peek always reads as a row.
    public static double SnappedViewport(IReadOnlyList<SessionListEntry> entries)
    {
        var total = entries.Sum(entry => entry.Height);
        if (total <= MaxViewport) return total;
        double best = 0, y = 0;
        foreach (var entry in entries)
        {
            IReadOnlyList<(double Top, double Height)> frames = entry switch
            {
                SessionListEntry.Block { Value: var block } => block.RowFrames,
                SessionListEntry.Older or SessionListEntry.Toggle => [(0, OlderHeight)],
                _ => [],
            };
            foreach (var (top, height) in frames)
            {
                double low = y + top + 12, high = y + top + height - 6;
                if (low <= MaxViewport) best = Math.Max(best, Math.Min(high, MaxViewport));
            }
            y += entry.Height;
        }
        return best > 0 ? best : MaxViewport;
    }

    /// `restart`: clients waiting for a relaunch, whose rows show no speed cell. `calendar` defaults to `DayCalendar.Current`.
    public static SessionListModel Make(IReadOnlyList<TokenReading> readings, DateTimeOffset now, bool expanded,
                                        IReadOnlySet<TokenSource>? restart = null, DayCalendar? calendar = null)
    {
        var restarting = restart ?? new HashSet<TokenSource>();
        var groups = SessionPresentation.Groups(readings, now);
        var stable = Comparer<SessionGroup>.Create((a, b) =>
        {
            var order = SessionPresentation.StandardCompare(a.Lead.Reading.Project ?? "", b.Lead.Reading.Project ?? "");
            if (order != 0) return order;
            if (a.Lead.Reading.SessionID != b.Lead.Reading.SessionID)
                return string.CompareOrdinal(a.Lead.Reading.SessionID ?? "", b.Lead.Reading.SessionID ?? "");
            return string.CompareOrdinal(a.Id, b.Id);
        });
        // A turn waiting for the person goes first; the rest of the running set keeps a stable order.
        var input = groups.Where(group => group.State == SessionDisplayState.Input).Order(stable);
        var running = groups.Where(group => group.State.IsRunning && group.State != SessionDisplayState.Input).Order(stable);
        var waiting = groups.Where(group => group.State == SessionDisplayState.Waiting).Order(stable);
        var measured = groups.Where(group => group.State == SessionDisplayState.Measurement
                                             && group.Lead.Reading.SpeedMeasurement?.At is { } at && (now - at).TotalSeconds is >= -5 and < 120)
            .OrderBy(group => group.Id, StringComparer.Ordinal);
        var pinnedGroups = input.Concat(running).Concat(waiting).Concat(measured).ToList();
        var pinned = pinnedGroups.Select(group => group.Id).ToHashSet();
        // Keys first: `LastActivity` scans every member, too slow to recompute per comparison on each sample.
        var rest = groups.Where(group => !pinned.Contains(group.Id)).Select(group => (Group: group, At: group.LastActivity))
            .OrderByDescending(item => item.At).ThenBy(item => item.Group.Id, StringComparer.Ordinal).Select(item => item.Group);
        var ordered = pinnedGroups.Concat(rest).ToList();
        var shown = expanded ? ordered : ordered.Take(Math.Max(pinned.Count, CollapsedMinimum)).ToList();

        bool MeasuredSpeed(TokenReading reading) => reading.SpeedMeasurement?.TokensPerSecond is not null && !restarting.Contains(reading.Source);
        var blocks = new List<SessionBlock>();
        int hiddenChildren = 0, olderCount = 0;
        var showsSpeedColumn = false;
        foreach (var group in shown)
        {
            var lead = group.Lead;
            var kind = lead.State == SessionDisplayState.Measurement ? SessionRowKind.Measurement
                : lead.State.IsLive ? SessionRowKind.Live : SessionRowKind.Idle;
            var live = group.Children.Where(child => child.State.IsLive)
                .OrderBy(child => child.State.IsRunning ? 0 : 1)
                .ThenBy(child => SessionPresentation.AgentLabel(child.Reading), Comparer<string>.Create(SessionPresentation.StandardCompare))
                .ThenBy(child => child.Reading.Id, StringComparer.Ordinal).ToList();
            var runningChildren = live.Count(child => child.State.IsRunning);
            // Collapsed: every running child shows; children waiting for a log take slots only when none runs.
            var room = expanded ? live.Count : runningChildren > 0 ? runningChildren : Math.Min(live.Count, CollapsedChildren);
            var children = live.Take(room).ToList();
            var cut = live.Skip(room).ToList();
            if (expanded)
                children.AddRange(group.Children.Where(child => !child.State.IsLive)
                    .OrderByDescending(child => child.Reading.LastActivity ?? DateTimeOffset.MinValue)
                    .ThenBy(child => child.Reading.Id, StringComparer.Ordinal));
            else hiddenChildren += group.Children.Count - children.Count;
            var leadItem = new SessionRowItem(lead.Reading, lead.State, kind);
            if (kind == SessionRowKind.Live)
            {
                leadItem = leadItem with
                {
                    ShowsDetail = SessionPresentation.LastRecord(lead.Reading) is not null || MeasuredSpeed(lead.Reading)
                                  || SessionPresentation.Context(lead.Reading, now) is not null,
                };
                if (MeasuredSpeed(lead.Reading)) showsSpeedColumn = true;
            }
            string? moreText = null, moreSpoken = null;
            if (cut.Count > 0)
            {
                var newest = cut.Select(child => SessionPresentation.LiveAt(child.Reading)).Max();
                string More(bool spoken) =>
                    Loc($"+{cut.Count} 하위 {SessionDisplayState.Waiting.Title}", $"+{Plural(cut.Count, "subagent")} waiting for log")
                    + (newest is { } at ? Loc(" · 마지막 ", " · last record ") + Format.Age(at, now, spoken) : "");
                (moreText, moreSpoken) = (More(false), More(true));
            }
            var section = expanded && !pinned.Contains(group.Id)
                ? SessionPresentation.DaySection(group.LastActivity, now, calendar ?? DayCalendar.Current) : null;
            if (section == SessionPresentation.OlderSection) olderCount++;
            blocks.Add(new SessionBlock(leadItem, children.Select(child => new SessionRowItem(child.Reading, child.State, SessionRowKind.Child)).ToList(),
                                        group.Children.Count, group.State)
            {
                RunningChildren = runningChildren, WaitingChildren = live.Count - runningChildren, MoreCount = cut.Count,
                MoreText = moreText ?? "", MoreSpoken = moreSpoken ?? "", Section = section,
            });
        }
        return new SessionListModel
        {
            Blocks = blocks, Counts = new SessionCounts(groups), Expanded = expanded,
            HiddenGroups = ordered.Count - shown.Count, HiddenChildren = hiddenChildren, OlderCount = olderCount,
            ShowsSpeedColumn = showsSpeedColumn,
        }.Measured();
    }
}
