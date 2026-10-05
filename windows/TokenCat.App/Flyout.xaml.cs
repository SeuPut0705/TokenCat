using System.Reflection;

namespace TokenCat;

public partial class Flyout : System.Windows.Window
{
    public Flyout()
    {
        InitializeComponent();
        var version = typeof(Flyout).Assembly.GetCustomAttribute<AssemblyInformationalVersionAttribute>()?.InformationalVersion;
        Header.Text = $"TokenCat {version}";
    }
}
