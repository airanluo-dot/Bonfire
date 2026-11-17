using Microsoft.UI.Xaml;
namespace Bonfire;
public partial class App : Application {
    private Window? window;
    public App() {
        var language=Preferences.Load().Language;
        Microsoft.Windows.Globalization.ApplicationLanguages.PrimaryLanguageOverride=language=="system"?"":language;
        InitializeComponent();
    }
    protected override void OnLaunched(LaunchActivatedEventArgs args) { window = new MainWindow(); window.Activate(); }
}
