namespace TokenCat;

/// The Swift suites' `check(condition, description)`. Ports keep each description verbatim (rule 1), so pass the same
/// prefix the Swift suite adds ("Localization: ", or none):
///   var c = new Check("Tracker"); void check(bool valid, string description) => c.That(valid, description);
///   …; return c.Done();
public sealed class Check(string title, string prefix = "")
{
    readonly List<string> failures = [];
    int count, skipped;

    public void That(bool valid, string description)
    {
        count++;
        if (!valid) failures.Add(prefix + description);
    }

    public void Skip() => skipped++;

    /// Prints the Swift tally line ("Tracker checks: 12 PASS / 0 FAIL / 0 SKIP") and returns the failures.
    public List<string> Done()
    {
        Console.WriteLine($"{title} checks: {count - failures.Count} PASS / {failures.Count} FAIL / {skipped} SKIP");
        return failures;
    }
}
