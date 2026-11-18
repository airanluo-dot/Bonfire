using Microsoft.UI.Xaml;
using Microsoft.UI.Xaml.Automation;
using Microsoft.UI.Xaml.Controls;
using Microsoft.UI.Xaml.Media;
using Microsoft.UI.Xaml.Media.Imaging;
using System.Text.Json.Nodes;
using Windows.Storage.Pickers;
using Microsoft.UI.Windowing;

namespace Bonfire;

public sealed partial class MainWindow : Window {
    readonly Preferences prefs = Preferences.Load();
    readonly Strings strings;
    readonly JsonArray games;
    string section = "work", game = "", extension = "", destination = "", package = "", digest = "";
    bool receiving, writing;
    JsonArray installs = [];
    JsonNode? selected, inventory, preview;
    CancellationTokenSource screen = new();
    TextBlock status = null!;
    string T(string key, params object[] args) => strings.Get(key,args);
    string GameName(string id) => T("Game_" + id);

    public MainWindow() {
        strings = new(prefs.Language);
        InitializeComponent();
        ExtendsContentIntoTitleBar = true;
        SetTitleBar(AppBar);
        Title = "Bonfire";
        AppWindow.SetIcon(System.IO.Path.Combine(AppContext.BaseDirectory,"app.ico"));
        AppWindow.Resize(new Windows.Graphics.SizeInt32(1080,760));
        AppWindow.Closing += async (_, e) => {
            if(writing){e.Cancel=true;return;}
            if(updates?.Busy==true){e.Cancel=true;await updates.Stop();Close();}
        };
        games = Native.Call(new { op="catalog" }).AsArray();
        updates=new(prefs,()=>!writing,Close);
        updates.Changed+=ShowUpdateControls;
        Nav.ItemInvoked += (_,e) => {
            if (!writing && e.InvokedItemContainer is NavigationViewItem item) Enter((string)item.Tag);
        };
        Closed += (_,_) => {screen.Cancel();updates.Reset();};
        Root.Language = strings.Culture.Name;
        Nav.SelectedItem = WorkNav;
        Enter("work");
        if(prefs.AutoCheck)DispatcherQueue.TryEnqueue(async()=>await updates.Check());
    }

    void Restart() { screen.Cancel(); screen.Dispose(); screen = new(); }
    void Enter(string target) {
        Restart();
        Root.Language=strings.Culture.Name;
        section=target; game=""; selected=null; inventory=null; preview=null; package=""; digest=""; receiving=false;
        updateGroup=null;
        destination=prefs.Destination; installs=[];
        WorkNav.Content=T("Workbench"); ManagerNav.Content=T("Manager"); SettingsNav.Content=T("Settings");
        foreach(var item in new[]{WorkNav,ManagerNav,SettingsNav}) {
            AutomationProperties.SetName(item,item.Content.ToString());
            ToolTipService.SetToolTip(item,item.Content);
        }
        if (section=="settings") SettingsPage(); else Library();
    }

    static TextBlock Text(string value, double size = 14) => new() { Text=value,FontSize=size,TextWrapping=TextWrapping.Wrap,IsTextSelectionEnabled=false };
    static StackPanel Stack(double space = 12) => new() { Spacing=space };
    static StackPanel Line() => new() { Orientation=Orientation.Horizontal,Spacing=8 };
    static Button Button(string label, Action action) {
        var b=new Button{Content=label}; b.Click+=(_,_)=>action(); return b;
    }
    void HeaderFor(string title) {
        Header.Children.Clear();
        if(section != "settings") Header.Children.Add(Text(T(section=="work"?"Workbench":"Manager"),14));
        var row=new Grid { ColumnSpacing=12 };
        row.ColumnDefinitions.Add(new(){Width=new GridLength(1,GridUnitType.Star)});
        row.ColumnDefinitions.Add(new(){Width=GridLength.Auto});
        var heading=Text(title,30); heading.FontWeight=Microsoft.UI.Text.FontWeights.SemiBold;
        AutomationProperties.SetHeadingLevel(heading,Microsoft.UI.Xaml.Automation.Peers.AutomationHeadingLevel.Level1);
        row.Children.Add(heading);
        if(game.Length>0) {var b=Button(T("ChangeGame"),()=>Enter(section));Grid.SetColumn(b,1);row.Children.Add(b);}
        Header.Children.Add(row);
    }
    void Body(FrameworkElement contents) {
        Surface.Content=new ScrollViewer { Content=contents,HorizontalScrollMode=ScrollMode.Disabled,HorizontalScrollBarVisibility=ScrollBarVisibility.Disabled,VerticalScrollBarVisibility=ScrollBarVisibility.Auto };
    }
    void Library() {
        HeaderFor(T("AppLibrary"));
        var grid=new GridView { IsItemClickEnabled=true,SelectionMode=ListViewSelectionMode.None,Padding=new Thickness(0),HorizontalAlignment=HorizontalAlignment.Stretch };
        foreach(var item in games) {
            var id=item!["id"]!.ToString(); if(prefs.Hidden.Contains(id)) continue;
            var tile=new StackPanel { Width=104,Spacing=8,Margin=new Thickness(6,10,6,10) };
            var icon=new Image { Width=72,Height=72,Source=new BitmapImage(new Uri("ms-appx:///Assets/Games/"+id+".png")),Stretch=Stretch.UniformToFill };
            tile.Children.Add(new Border{Child=icon,Width=72,Height=72,CornerRadius=new CornerRadius(15)});
            var label=Text(GameName(id));label.TextAlignment=TextAlignment.Center;tile.Children.Add(label);
            var entry=new GridViewItem{ Content=tile,Tag=id };
            AutomationProperties.SetName(entry,GameName(id));AutomationProperties.SetAutomationId(entry,"LibraryTile_"+id);
            grid.Items.Add(entry);
        }
        grid.ItemClick+=(_,e)=> {
            var entry=e.ClickedItem as GridViewItem ?? grid.ContainerFromItem(e.ClickedItem) as GridViewItem;
            if(entry==null && e.ClickedItem is StackPanel panel) entry=grid.Items.Cast<GridViewItem>().FirstOrDefault(x=>ReferenceEquals(x.Content,panel));
            if(entry?.Tag is string id) OpenGame(id);
        };
        Surface.Content=grid.Items.Count==0?Text(T("NoGames")):grid;
    }
    void OpenGame(string id) {
        Restart(); game=id; extension=games.First(x=>x!["id"]!.ToString()==id)!["ext"]!.ToString();
        if(section=="work") {Workspace(); Locate();} else Timeline();
    }

    Border Card(UIElement content) => new() { Child=content,Padding=new Thickness(16),CornerRadius=new CornerRadius(8),BorderThickness=new Thickness(1),
        Background=(Brush)Application.Current.Resources["CardBackgroundFillColorDefaultBrush"],BorderBrush=(Brush)Application.Current.Resources["CardStrokeColorDefaultBrush"] };
    StackPanel Group(StackPanel page,string title) {
        var group=Stack(8);var label=Text(title,16);label.FontWeight=Microsoft.UI.Text.FontWeights.SemiBold;
        group.Children.Add(label); page.Children.Add(Card(group));return group;
    }
    string Progress(JsonNode p,bool found) {
        var count=p["count"]!.GetValue<int>();
        if(count==0)return T(p["persistent"]!.GetValue<bool>()?"PersistentOnly":"NoneProgress");
        var summary=T("OneProgress");var time=p["playtime"]!.ToString();
        var label=count>1 && time.Length>0?T("SlotPlaytime",p["slot"]!.ToString()):T("Playtime");
        var prefix=(found?T("Found",summary):summary);
        return T("ProgressLine",prefix,T("LabelValue",label,time.Length>0?time:T("Unknown")));
    }
    void Workspace(string message="") {
        HeaderFor(GameName(game));
        var selector=new SelectorBar();
        selector.Items.Add(new SelectorBarItem{Text=T("Extract")});selector.Items.Add(new SelectorBarItem{Text=T("Receive")});
        selector.SelectedItem=selector.Items[receiving?1:0];
        selector.SelectionChanged+=(_,_)=>{var next=selector.SelectedItem==selector.Items[1];if(!writing && next!=receiving){receiving=next;Workspace();}};
        Header.Children.Add(selector);
        var page=Stack(); var location=Group(page,T("GameLocation"));
        if(installs.Count>1) {
            var list=new ComboBox { PlaceholderText=T("ManyInstalls"),HorizontalAlignment=HorizontalAlignment.Stretch };
            foreach(var i in installs)list.Items.Add(i!["install"]!.ToString());
            list.SelectedIndex=selected is null?-1:installs.IndexOf(selected);
            list.SelectionChanged+=(_,_)=>{if(list.SelectedIndex>=0){Restart();selected=installs[list.SelectedIndex];inventory=null;RefreshTarget();}};
            location.Children.Add(list);
        } else location.Children.Add(Text(selected?["install"]?.ToString()??T("NotSelected")));
        if(selected!=null)location.Children.Add(Text(T("LabelValue",T("SaveLocation"),selected["save"]!.ToString())));
        var controls=Line();
        controls.Children.Add(Button(T("Locate"),()=>Locate()));
        controls.Children.Add(Button(T("ChooseInstall"),()=>PickInstall()));
        location.Children.Add(controls);
        if(receiving) {
            var file=Group(page,T("Package"));file.Children.Add(Text(package.Length>0?package:T("NotSelected")));
            file.Children.Add(Button(T("ChooseFile"),()=>PickPackage()));
            if(preview!=null) {
                file.Children.Add(Text(Progress(preview["progress"]!,false)));
                foreach(var notice in preview["notices"]!.AsArray()) file.Children.Add(Text(T(notice!.ToString())));
                if(preview["blocking"] is JsonObject issue)
                    file.Children.Add(Text(T(issue["key"]!.ToString(),issue["args"]!.AsArray().Select(a=>(object)a!.ToString()).ToArray())));
            }
        } else {
            if(inventory!=null)location.Children.Add(Text(Progress(inventory,true)));
            var folder=Group(page,T("SaveTo"));folder.Children.Add(Text(destination));
            folder.Children.Add(Button(T("ChooseFolder"),async ()=>{var chosen=await Pick(true);if(chosen!=null){destination=chosen;Workspace();}}));
        }
        status=Text(message);page.Children.Add(status);
        var go=Button(T(receiving?"Replace":"Extract"),()=>Transfer());
        go.IsEnabled=selected!=null && (receiving?preview!=null && preview["blocking"]==null:inventory?["available"]?.GetValue<bool>()==true);
        go.Style=(Style)Application.Current.Resources["AccentButtonStyle"];page.Children.Add(go);Body(page);
    }
    async Task<JsonNode?> Run(object request,CancellationToken token) {
        try {var result=await Task.Run(()=>Native.Call(request,token),token);return token.IsCancellationRequested?null:result;}
        catch(OperationCanceledException){return null;}
        catch(Exception ex){if(!token.IsCancellationRequested)status.Text=ErrorText(ex);return null;}
    }
    string ErrorText(Exception e)=>e is ServiceError err ? T(err.Message,err.Values) : T("Unexpected",e.Message);
    async void Locate(string? path=null) {
        Restart(); var token=screen.Token;selected=null;installs=[];inventory=null;preview=null;digest="";Workspace(T("Finding"));
        var found=await Run(new {op=path==null?"locate":"identify",game,path},token);
        if(found==null||token.IsCancellationRequested)return;
        installs=found.AsArray();selected=installs.Count==1?installs[0]:null;
        if(selected!=null) RefreshTarget();
        else Workspace(T(installs.Count>1?"ManyInstalls":"NoInstall"));
    }
    void RefreshTarget(){
        preview=null;digest="";Workspace();ReadInventory();
        if(package.Length>0) PreviewPackage(package);
    }
    async void ReadInventory(){
        var token=screen.Token;
        var result=await Run(new {op="inventory",game,root=selected!["root"]!.ToString()},token);
        if(result!=null&&!token.IsCancellationRequested){inventory=result;Workspace();}
    }
    async Task<string?> Pick(bool folder) {
        var hwnd=WinRT.Interop.WindowNative.GetWindowHandle(this);
        try {
            if(folder){var panel=new FolderPicker();panel.FileTypeFilter.Add("*");WinRT.Interop.InitializeWithWindow.Initialize(panel,hwnd);return (await panel.PickSingleFolderAsync())?.Path;}
            var file=new FileOpenPicker();file.FileTypeFilter.Add("."+extension);WinRT.Interop.InitializeWithWindow.Initialize(file,hwnd);return (await file.PickSingleFileAsync())?.Path;
        } catch(Exception e){status.Text=ErrorText(e);return null;}
    }
    async void PickInstall(){var p=await Pick(true);if(p!=null)Locate(p);}
    int previewGeneration;
    async void PickPackage() {
        var token=screen.Token;var path=await Pick(false);if(path==null||token.IsCancellationRequested)return;
        PreviewPackage(path);
    }
    async void PreviewPackage(string path) {
        var token=screen.Token;
        var sequence=++previewGeneration;package=path;preview=null;digest="";Workspace(T("Busy"));
        var result=await Run(new{op="preview",game,path,root=selected?["root"]?.ToString()},token);
        if(sequence==previewGeneration&&result!=null&&!token.IsCancellationRequested){preview=result;digest=result["checksum"]!.ToString();Workspace();}
    }
    async void Transfer(){
        if(writing || selected==null)return;
        writing=true;Nav.IsEnabled=false;Surface.IsEnabled=false;Header.IsHitTestVisible=false;status.Text=T("Busy");
        try{
            var root=selected["root"]!.ToString();
            var result=await Run(new{op=receiving?"import":"export",game,root,title=GameName(game),folder=destination,path=package,checksum=digest},screen.Token);
            if(result==null)return;
            var folder=receiving?System.IO.Path.GetDirectoryName(package)!:destination;
            var success=receiving?T("Imported"):T("Exported",result.ToString());
            if(receiving) {inventory=await Run(new {op="inventory",game,root},screen.Token);}
            try{prefs.Remember(folder);}catch(Exception e){success+="\n"+ErrorText(e);}
            Workspace(success);
        }finally{writing=false;Nav.IsEnabled=true;Surface.IsEnabled=true;Header.IsHitTestVisible=true;_ = updates.ApplyAutomaticIfReady();}
    }
    async void Timeline(string? single=null) {
        Restart();var token=screen.Token;
        HeaderFor(GameName(game));var page=Stack();var title=Text(T("Timeline"),20);page.Children.Add(title);
        var controls=Line();controls.Children.Add(Button(T("Refresh"),()=>Timeline(single)));
        controls.Children.Add(Button(T("ChooseFolder"),async()=>{var folder=await Pick(true);if(folder!=null)Timeline(folder);}));
        if(single!=null)controls.Children.Add(Button(T("ResetFolder"),()=>Timeline()));
        page.Children.Add(controls);if(single!=null)page.Children.Add(Text(single));
        status=Text(T("Loading"));page.Children.Add(status);Body(page);
        var folders=single==null?new[]{prefs.Destination}.Concat(prefs.PackageFolders).Distinct(StringComparer.OrdinalIgnoreCase).ToArray():[single];
        var result=await Run(new{op="timeline",game,folders},token);
        if(result==null||token.IsCancellationRequested)return;
        var rows=result["rows"]!.AsArray();
        var skipped=result["skipped"]!.GetValue<int>();
        status.Text=string.Join("\n",new[]{rows.Count==0?T("TimelineEmpty"):"",skipped>0?T("Skipped",skipped):""}.Where(x=>x.Length>0));
        status.Visibility=status.Text.Length==0?Visibility.Collapsed:Visibility.Visible;
        foreach(var record in rows){
            var card=Group(page,record!["name"]!.ToString());
            var created=record["created"]!.GetValue<long>();var p=record["progress"]!;
            card.Children.Add(Text(T("LabelValue",T("Generated"),created>0?DateTimeOffset.FromUnixTimeMilliseconds(created).LocalDateTime.ToString("G",strings.Culture):T("NoTime"))));
            var time=p["playtime"]!.ToString();card.Children.Add(Text(T("LabelValue",T("Playtime"),time.Length>0?time:T("Unknown"))));
            ToolTipService.SetToolTip(card,record["path"]!.ToString());
        }
    }
    void SaveSettings(){try{prefs.Save();}catch(Exception e){status.Text=ErrorText(e);}}
    void SettingsPage(){
        HeaderFor(T("Settings"));var page=Stack();status=Text("");
        var languages=Group(page,T("Language"));var choice=new ComboBox();
        string[] tags=["system","zh-Hans","en"];foreach(var key in new[]{"System","Chinese","English"})choice.Items.Add(T(key));
        choice.SelectedIndex=Math.Max(0,Array.IndexOf(tags,prefs.Language));languages.Children.Add(choice);languages.Children.Add(Text(T("SystemLanguageNote")));
        choice.SelectionChanged+=(_,_)=>{if(choice.SelectedIndex>=0){prefs.Language=tags[choice.SelectedIndex];strings.Set(prefs.Language);Enter("settings");SaveSettings();}};
        var folder=Group(page,T("DefaultFolder"));folder.Children.Add(Text(prefs.Destination));var actions=Line();
        actions.Children.Add(Button(T("ChooseFolder"),async()=>{var chosen=await Pick(true);if(chosen!=null){prefs.Folder=chosen;SettingsPage();SaveSettings();}}));
        actions.Children.Add(Button(T("ResetFolder"),()=>{prefs.Folder="";SettingsPage();SaveSettings();}));folder.Children.Add(actions);
        var visible=Group(page,T("VisibleGames"));
        foreach(var entry in games){var id=entry!["id"]!.ToString();var box=new CheckBox{Content=GameName(id),IsChecked=!prefs.Hidden.Contains(id)};
            box.Click+=(_,_)=>{if(box.IsChecked==true)prefs.Hidden.Remove(id);else prefs.Hidden.Add(id);SaveSettings();};visible.Children.Add(box);}
        updateGroup=Group(page,T("Updates"));ShowUpdateControls();page.Children.Add(status);Body(page);
    }
}
