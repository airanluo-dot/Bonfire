using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Controls;

namespace Bonfire;
public sealed partial class MainWindow {
    readonly ReleaseUpdates updates;
    StackPanel? updateGroup;
    void ShowUpdateControls(){
        if(section!="settings" || updateGroup==null)return;
        var panel=updateGroup;panel.Children.Clear();
        var heading=Text(T("Updates"),16);heading.FontWeight=Microsoft.UI.Text.FontWeights.SemiBold;panel.Children.Add(heading);
        void Toggle(string key,bool value,Action<bool> setter,bool enabled=true){
            var item=new ToggleSwitch{Header=T(key),IsOn=value,IsEnabled=enabled,OnContent=T("On"),OffContent=T("Off")};
            item.Toggled+=(_,_)=>{setter(item.IsOn);SaveSettings();};panel.Children.Add(item);
        }
        Toggle("UpdateAutoCheck",prefs.AutoCheck,b=>prefs.AutoCheck=b);
        Toggle("UpdateAutoDownload",prefs.AutoDownload,b=>prefs.AutoDownload=b);
        Toggle("UpdateAutoInstall",prefs.AutoInstall,b=>prefs.AutoInstall=b,updates.Installed);
        var channel=new ComboBox{Header=T("UpdateChannel")};channel.Items.Add(T("Stable"));channel.Items.Add(T("Beta"));
        channel.SelectedIndex=prefs.Channel=="Beta"?1:0;
        channel.SelectionChanged+=(_,_)=>{
            prefs.Channel=channel.SelectedIndex==1?"Beta":"Stable";updates.Reset();SaveSettings();
            if(prefs.AutoCheck)_=updates.Check();
        };
        panel.Children.Add(channel);panel.Children.Add(Text(T("UpdateChannelsHelp")));
        panel.Children.Add(Text(T("UpdateBuild",ReleaseUpdates.Version,T(updates.Installed?"Installed":"Portable"))));
        panel.Children.Add(Text(updates.Status=="UpdateAvailable"?T("UpdateAvailable",updates.CandidateVersion):T(updates.Status)));
        if(prefs.LastCheck is DateTimeOffset date)panel.Children.Add(Text(T("UpdateLast",date.LocalDateTime.ToString("G",strings.Culture))));
        var buttons=Line();
        var check=Button(T("UpdateCheck"),async()=>await updates.Check());check.IsEnabled=!updates.Busy;buttons.Children.Add(check);
        if(updates.Candidate!=null && !updates.Busy){
            if(updates.LocalFile==null)buttons.Children.Add(Button(T("UpdateDownload"),async()=>await updates.Download()));
            else if(updates.Installed)buttons.Children.Add(Button(T("UpdateInstall"),async()=>await updates.Install()));
            else buttons.Children.Add(Button(T("UpdateShow"),updates.Reveal));
        }
        panel.Children.Add(buttons);
    }
}
