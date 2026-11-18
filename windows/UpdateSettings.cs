using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;

namespace Bonfire;
public sealed partial class MainWindow {
    readonly ReleaseUpdates updates;
    StackPanel? updateGroup;
    TextBlock updateState = null!, updateTime = null!;
    ProgressBar updateProgress = null!;
    Button checkUpdate = null!, actOnUpdate = null!, cancelUpdate = null!;
    ComboBox updateChannel = null!;

    void BuildUpdateControls(StackPanel panel) {
        panel.Children.Add(Text(T("UpdateBuild", ReleaseUpdates.Version, T(updates.Installed ? "Installed" : "Portable"))));
        updateState = Text("");
        AutomationProperties.SetLiveSetting(updateState, Microsoft.UI.Xaml.Automation.Peers.AutomationLiveSetting.Polite);
        AutomationProperties.SetAutomationId(updateState, "UpdateStatus");
        panel.Children.Add(updateState);
        updateProgress = new ProgressBar { Minimum=0, Maximum=100, HorizontalAlignment=HorizontalAlignment.Stretch };
        AutomationProperties.SetName(updateProgress,T("UpdateDownload"));
        panel.Children.Add(updateProgress);
        updateTime = Text("",12);
        panel.Children.Add(updateTime);

        var actions=Line();
        checkUpdate=Button(T("UpdateCheck"),async()=>await updates.Check());
        actOnUpdate=Button(T("UpdateDownload"),async()=>{
            if(updates.LocalFile==null) await updates.Download();
            else if(updates.Installed) await updates.Install();
            else updates.Reveal();
        });
        cancelUpdate=Button(T("UpdateCancel"),async()=>await updates.Stop());
        AutomationProperties.SetAutomationId(checkUpdate,"UpdateCheck");
        AutomationProperties.SetAutomationId(actOnUpdate,"UpdateAction");
        AutomationProperties.SetAutomationId(cancelUpdate,"UpdateCancel");
        actions.Children.Add(checkUpdate);actions.Children.Add(actOnUpdate);actions.Children.Add(cancelUpdate);
        panel.Children.Add(actions);

        var channelRow=Line();
        channelRow.Children.Add(new TextBlock{Text=T("UpdateChannel"),VerticalAlignment=VerticalAlignment.Center});
        updateChannel=new ComboBox();
        updateChannel.Items.Add(T("Stable"));updateChannel.Items.Add(T("Beta"));
        updateChannel.SelectedIndex=prefs.Channel=="Beta"?1:0;
        AutomationProperties.SetName(updateChannel,T("UpdateChannel"));
        ToolTipService.SetToolTip(updateChannel,T("UpdateChannelsHelp"));
        updateChannel.SelectionChanged+=(_,_)=>{
            if(updateChannel.SelectedIndex<0)return;
            var selectedChannel=updateChannel.SelectedIndex==1?"Beta":"Stable";
            if(prefs.Channel==selectedChannel)return;
            prefs.Channel=selectedChannel;prefs.LastCheck=null;
            updates.Reset();SaveSettings();
            if(prefs.AutoCheck)_=updates.Check();
        };
        channelRow.Children.Add(updateChannel);
        panel.Children.Add(channelRow);

        void AddSwitch(string key, bool value, Action<bool> change) {
            var row=new Grid{ColumnSpacing=16,MinWidth=240,HorizontalAlignment=HorizontalAlignment.Left};
            row.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});
            row.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
            var label=Text(T(key));label.VerticalAlignment=VerticalAlignment.Center;
            var toggle=new ToggleSwitch{IsOn=value,OnContent="",OffContent="",MinWidth=0};
            AutomationProperties.SetName(toggle,T(key));
            toggle.Toggled+=(_,_)=>{change(toggle.IsOn);SaveSettings();};
            row.Children.Add(label);Grid.SetColumn(toggle,1);row.Children.Add(toggle);
            panel.Children.Add(row);
        }
        AddSwitch("UpdateAutoCheck",prefs.AutoCheck,b=>prefs.AutoCheck=b);
        AddSwitch("UpdateAutoDownload",prefs.AutoDownload,b=>prefs.AutoDownload=b);
        if(updates.Installed)
            AddSwitch("UpdateAutoInstall",prefs.AutoInstall,b=>{prefs.AutoInstall=b;_ = updates.ApplyAutomaticIfReady();});
        ShowUpdateControls();
    }

    void ShowUpdateControls(){
        if(section!="settings" || updateGroup==null)return;
        var state=updates.Status;
        var message=state=="UpdateAvailable"?T(state,updates.CandidateVersion):T(state);
        if(state=="UpdateRateLimited" && updates.RetryAfter is DateTimeOffset retry && retry>DateTimeOffset.Now)
            message+=" "+T("UpdateRetryAt",retry.LocalDateTime.ToString("t",strings.Culture));
        if(state=="UpdateDownloading" && updates.DownloadPercent is int percent)
            message+=" "+(percent/100.0).ToString("P0",strings.Culture);
        if(updateState.Text!=message) updateState.Text=message;
        updateProgress.Visibility=updates.Busy?Visibility.Visible:Visibility.Collapsed;
        updateProgress.IsIndeterminate=state!="UpdateDownloading" || updates.DownloadPercent==null;
        updateProgress.Value=updates.DownloadPercent??0;
        updateTime.Text=prefs.LastCheck is DateTimeOffset last
            ?T("UpdateLast",last.LocalDateTime.ToString("g",strings.Culture)):"";
        updateTime.Visibility=updateTime.Text.Length==0?Visibility.Collapsed:Visibility.Visible;

        bool idle=!updates.Busy && !updates.Installing;
        updateChannel.IsEnabled=!updates.Installing;
        checkUpdate.Visibility=idle?Visibility.Visible:Visibility.Collapsed;
        actOnUpdate.Visibility=idle && updates.Candidate!=null?Visibility.Visible:Visibility.Collapsed;
        actOnUpdate.Content=T(updates.LocalFile==null?"UpdateDownload":updates.Installed?"UpdateInstall":"UpdateShow");
        checkUpdate.Content=T(updates.Candidate==null && state is not ("UpdateIdle" or "UpdateCurrent")?"UpdateRetry":"UpdateCheck");
        cancelUpdate.Visibility=updates.Busy && !updates.Installing?Visibility.Visible:Visibility.Collapsed;
    }
}
