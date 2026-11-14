#Requires -Version 5.1
# Iran Kill Switch - desktop app (WPF, built into Windows; nothing to install).
# All work runs in background runspaces that load IKS.ps1; the window never freezes.

$ErrorActionPreference = 'Stop'
$Entry = Join-Path $PSScriptRoot 'IKS.ps1'

# ---- elevate + single instance ------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal ([Security.Principal.WindowsIdentity]::GetCurrent())
$SelfTest = $env:IKS_GUI_SELFTEST   # developer check: path of a PNG to render, no admin, no window
$DevRun = $env:IKS_GUI_DEV -eq '1'  # developer run: real window without elevation (read-only actions only)
if (-not $SelfTest -and -not $DevRun -and -not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    # Prefer the windowless launcher (it asks for admin itself); fall back to PowerShell.
    $launcher = Join-Path $PSScriptRoot 'IranKillSwitch.exe'
    if (Test-Path $launcher) { Start-Process $launcher }
    else {
        Start-Process "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -Verb RunAs `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File `"$PSCommandPath`""
    }
    exit
}
# Single instance: a second launch just brings the running window forward
$script:Single = New-Object System.Threading.Mutex($false, 'Local\IranKillSwitch-GUI')
$script:ShowEvent = New-Object System.Threading.EventWaitHandle($false, [System.Threading.EventResetMode]::AutoReset, 'Local\IranKillSwitch-GUI-Show')
if (-not $SelfTest) {
    $owned = $false
    try { $owned = $script:Single.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $owned = $true }
    if (-not $owned) { $null = $script:ShowEvent.Set(); exit }
}

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
trap { [Windows.MessageBox]::Show("Iran Kill Switch could not start:`n`n$_", 'Iran Kill Switch') | Out-Null; exit 1 }
# Own taskbar identity: the taskbar shows the app's icon instead of grouping it under powershell.exe
Add-Type -Namespace IKSWin -Name Shell -MemberDefinition '[DllImport("shell32.dll", CharSet = CharSet.Unicode)] public static extern int SetCurrentProcessExplicitAppUserModelID(string id);'
$null = [IKSWin.Shell]::SetCurrentProcessExplicitAppUserModelID('Mansoor.IranKillSwitch')
. $Entry     # functions + paths for quick, local reads (log path, version)

# ---- design tokens ---------------------------------------------------------
$T = @{ Bg = '#0E1014'; Surface = '#161A21'; Surface2 = '#1C212A'; Line = '#262C36'; Text = '#E9ECF1'; Muted = '#8A93A3'
        Green = '#34D399'; Amber = '#FBBF24'; Red = '#F87171'; Off = '#4B5563'; Accent = '#60A5FA' }

[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Iran Kill Switch" SizeToContent="WidthAndHeight" WindowStartupLocation="CenterScreen"
        WindowStyle="None" AllowsTransparency="True" Background="Transparent" ResizeMode="CanMinimize"
        FontFamily="Segoe UI Variable Text, Segoe UI" Foreground="$($T.Text)" UseLayoutRounding="True">
  <Window.Resources>
    <Style x:Key="Btn" TargetType="Button">
      <Setter Property="Foreground" Value="$($T.Text)"/>
      <Setter Property="Background" Value="$($T.Surface2)"/>
      <Setter Property="BorderBrush" Value="$($T.Line)"/>
      <Setter Property="FontSize" Value="13"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Padding" Value="14,10"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="b" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}"
                    BorderThickness="1" CornerRadius="10" Padding="{TemplateBinding Padding}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.85"/></Trigger>
              <Trigger Property="IsPressed" Value="True"><Setter TargetName="b" Property="Opacity" Value="0.7"/></Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="b" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Link" TargetType="Button">
      <Setter Property="Foreground" Value="$($T.Muted)"/>
      <Setter Property="FontSize" Value="12"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <ContentPresenter x:Name="t" Margin="8,0" TextBlock.Foreground="{TemplateBinding Foreground}"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="t" Property="TextBlock.Foreground" Value="$($T.Text)"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Chrome" TargetType="Button" BasedOn="{StaticResource Link}">
      <Setter Property="FontFamily" Value="Segoe MDL2 Assets"/>
      <Setter Property="FontSize" Value="10"/>
    </Style>
    <Style x:Key="Key" TargetType="TextBlock">
      <Setter Property="Foreground" Value="$($T.Muted)"/><Setter Property="FontSize" Value="12.5"/>
    </Style>
    <Style x:Key="Val" TargetType="TextBlock">
      <Setter Property="FontSize" Value="12.5"/><Setter Property="HorizontalAlignment" Value="Right"/>
      <Setter Property="TextTrimming" Value="CharacterEllipsis"/>
    </Style>
    <!-- ring switch: no chrome; grows on hover, presses in on click, focus ring for keyboard users -->
    <Style x:Key="RingButton" TargetType="Button">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="FocusVisualStyle" Value="{x:Null}"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Grid Background="Transparent">
              <Ellipse x:Name="focus" Stroke="$($T.Accent)" StrokeThickness="1.5" StrokeDashArray="2 3" Opacity="0"/>
              <ContentPresenter x:Name="cp" HorizontalAlignment="Center" VerticalAlignment="Center" RenderTransformOrigin="0.5,0.5">
                <ContentPresenter.RenderTransform><ScaleTransform x:Name="sc" ScaleX="1" ScaleY="1"/></ContentPresenter.RenderTransform>
              </ContentPresenter>
            </Grid>
            <ControlTemplate.Triggers>
              <Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="focus" Property="Opacity" Value="0.8"/></Trigger>
              <Trigger Property="IsMouseOver" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1.04" Duration="0:0:0.18"><DoubleAnimation.EasingFunction><QuadraticEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction></DoubleAnimation>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1.04" Duration="0:0:0.18"><DoubleAnimation.EasingFunction><QuadraticEase EasingMode="EaseOut"/></DoubleAnimation.EasingFunction></DoubleAnimation>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1" Duration="0:0:0.22"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1" Duration="0:0:0.22"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Trigger.EnterActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="0.95" Duration="0:0:0.08"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="0.95" Duration="0:0:0.08"/>
                </Storyboard></BeginStoryboard></Trigger.EnterActions>
                <Trigger.ExitActions><BeginStoryboard><Storyboard>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleX" To="1.04" Duration="0:0:0.14"/>
                  <DoubleAnimation Storyboard.TargetName="sc" Storyboard.TargetProperty="ScaleY" To="1.04" Duration="0:0:0.14"/>
                </Storyboard></BeginStoryboard></Trigger.ExitActions>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="cp" Property="Opacity" Value="0.5"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <!-- thin dark scrollbar that floats over the right gutter (no layout shift) -->
    <Style x:Key="ThinThumb" TargetType="Thumb">
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Thumb">
            <Border x:Name="b" CornerRadius="3" Background="$($T.Line)"/>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True"><Setter TargetName="b" Property="Background" Value="$($T.Off)"/></Trigger>
              <Trigger Property="IsDragging" Value="True"><Setter TargetName="b" Property="Background" Value="$($T.Muted)"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style TargetType="ScrollBar">
      <Setter Property="Width" Value="6"/>
      <Setter Property="MinWidth" Value="6"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollBar">
            <Track x:Name="PART_Track" IsDirectionReversed="True">
              <Track.Thumb><Thumb Style="{StaticResource ThinThumb}" MinHeight="24"/></Track.Thumb>
            </Track>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Scroll" TargetType="ScrollViewer">
      <Setter Property="VerticalScrollBarVisibility" Value="Auto"/>
      <Setter Property="HorizontalScrollBarVisibility" Value="Disabled"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="ScrollViewer">
            <Grid>
              <ScrollContentPresenter/>
              <ScrollBar x:Name="PART_VerticalScrollBar" HorizontalAlignment="Right" Margin="0,4,6,4"
                         Value="{TemplateBinding VerticalOffset}" Maximum="{TemplateBinding ScrollableHeight}"
                         ViewportSize="{TemplateBinding ViewportHeight}" Visibility="{TemplateBinding ComputedVerticalScrollBarVisibility}"/>
            </Grid>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
    <Style x:Key="Switch" TargetType="CheckBox">
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="CheckBox">
            <Border x:Name="track" Width="34" Height="18" CornerRadius="9" Background="$($T.Off)">
              <Ellipse x:Name="knob" Width="14" Height="14" Fill="$($T.Text)" HorizontalAlignment="Left" Margin="2,0"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsChecked" Value="True">
                <Setter TargetName="track" Property="Background" Value="$($T.Green)"/>
                <Setter TargetName="knob" Property="HorizontalAlignment" Value="Right"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False"><Setter TargetName="track" Property="Opacity" Value="0.4"/></Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Border x:Name="Root" Width="440" Background="$($T.Bg)" CornerRadius="18" BorderBrush="$($T.Line)" BorderThickness="1">
   <Grid>
    <Grid.RowDefinitions><RowDefinition Height="Auto"/><RowDefinition Height="*"/></Grid.RowDefinitions>
      <!-- title bar (fixed; the rest scrolls on small screens) -->
      <Grid x:Name="TitleBar" Grid.Row="0" Background="Transparent" Height="30" Margin="22,12,22,0">
        <StackPanel Orientation="Horizontal" VerticalAlignment="Center">
          <TextBlock FontFamily="Segoe MDL2 Assets" Text="&#xEA18;" FontSize="14" Foreground="$($T.Accent)" VerticalAlignment="Center"/>
          <TextBlock Text="Iran Kill Switch" FontWeight="SemiBold" FontSize="13" Margin="8,0,0,0" VerticalAlignment="Center"/>
          <TextBlock x:Name="Ver" Foreground="$($T.Muted)" FontSize="11" Margin="8,1,0,0" VerticalAlignment="Center"/>
        </StackPanel>
        <StackPanel Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
          <Button x:Name="BtnMin" Style="{StaticResource Chrome}" Content="&#xE921;"/>
          <Button x:Name="BtnClose" Style="{StaticResource Chrome}" Content="&#xE8BB;"/>
        </StackPanel>
      </Grid>

    <!-- main content: fixed height, no scrolling (results open in a card) -->
    <StackPanel Grid.Row="1" Margin="22,0,22,16">
      <!-- the ring IS the on/off switch (keyboard: Tab, then Enter/Space) -->
      <!-- 180 px box (layout height unchanged by the margins): room for the glow and its blur, so it is never clipped -->
      <Button x:Name="RingBtn" Style="{StaticResource RingButton}" Width="180" Height="180" Margin="0,2,0,-8"
              ToolTip="Click to turn protection on or off. Turning on asks you to confirm within 2 minutes, otherwise it is undone automatically.">
       <Grid Width="180" Height="180">
        <Ellipse x:Name="RingGlow" Width="162" Height="162" Stroke="$($T.Off)" StrokeThickness="12" Opacity="0.18">
          <Ellipse.Effect><BlurEffect Radius="7"/></Ellipse.Effect>
        </Ellipse>
        <Grid x:Name="Ring" Width="150" Height="150">
          <Ellipse Stroke="$($T.Line)" StrokeThickness="12"/>
          <Ellipse x:Name="RingArc" Stroke="$($T.Off)" StrokeThickness="12" RenderTransformOrigin="0.5,0.5">
            <Ellipse.RenderTransform><RotateTransform Angle="-90"/></Ellipse.RenderTransform>
          </Ellipse>
          <Ellipse x:Name="RingFace" Fill="$($T.Surface)" Margin="18"/>
          <StackPanel VerticalAlignment="Center" HorizontalAlignment="Center" IsHitTestVisible="False">
            <TextBlock x:Name="RingIcon" FontFamily="Segoe MDL2 Assets" Text="&#xE7E8;" FontSize="20" HorizontalAlignment="Center" Foreground="$($T.Off)"/>
            <TextBlock x:Name="RingText" Text="..." FontSize="30" FontWeight="Bold" HorizontalAlignment="Center" Margin="0,1,0,0" Foreground="$($T.Text)"/>
            <TextBlock x:Name="RingHint" Text="" FontSize="9.5" Foreground="$($T.Muted)" HorizontalAlignment="Center"/>
          </StackPanel>
        </Grid>
       </Grid>
      </Button>
      <TextBlock x:Name="Headline" Text="Checking..." FontSize="18" FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,10,0,0"/>
      <TextBlock x:Name="Sub" Text="" FontSize="12.5" Foreground="$($T.Muted)" TextAlignment="Center" TextWrapping="Wrap" Margin="10,4,10,0"/>

      <!-- facts -->
      <Border Background="$($T.Surface)" CornerRadius="12" Padding="16,12" Margin="0,14,0,0">
        <Grid>
          <Grid.ColumnDefinitions><ColumnDefinition Width="Auto"/><ColumnDefinition Width="Auto"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions>
          <Grid.RowDefinitions><RowDefinition Height="28"/><RowDefinition Height="28"/><RowDefinition Height="28"/><RowDefinition Height="28"/><RowDefinition Height="28"/></Grid.RowDefinitions>
          <Ellipse x:Name="DotVpn"   Grid.Row="0" Width="7" Height="7" Fill="$($T.Off)" Margin="0,0,10,0"/>
          <Ellipse x:Name="DotApps"  Grid.Row="1" Width="7" Height="7" Fill="$($T.Off)" Margin="0,0,10,0"/>
          <Ellipse x:Name="DotIran"  Grid.Row="2" Width="7" Height="7" Fill="$($T.Off)" Margin="0,0,10,0"/>
          <Ellipse x:Name="DotList"  Grid.Row="3" Width="7" Height="7" Fill="$($T.Off)" Margin="0,0,10,0"/>
          <Ellipse x:Name="DotGuard" Grid.Row="4" Width="7" Height="7" Fill="$($T.Off)" Margin="0,0,10,0"/>
          <TextBlock Grid.Row="0" Grid.Column="1" Style="{StaticResource Key}" Text="VPN" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="1" Grid.Column="1" Style="{StaticResource Key}" Text="VPN apps" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="2" Grid.Column="1" Style="{StaticResource Key}" Text="Iran direct (TUN)" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="3" Grid.Column="1" Style="{StaticResource Key}" Text="Iran IP list" VerticalAlignment="Center"/>
          <TextBlock Grid.Row="4" Grid.Column="1" Style="{StaticResource Key}" Text="Background guard" VerticalAlignment="Center"/>
          <TextBlock x:Name="ValVpn"   Grid.Row="0" Grid.Column="2" Style="{StaticResource Val}" VerticalAlignment="Center" Margin="12,0,0,0"/>
          <StackPanel Grid.Row="1" Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <TextBlock x:Name="ValApps" Style="{StaticResource Val}" VerticalAlignment="Center"/>
            <Button x:Name="BtnApps" Style="{StaticResource Link}" ToolTip="See, add or remove the VPN programs that may connect while protection is on." Content="Manage" Foreground="$($T.Accent)"/>
          </StackPanel>
          <StackPanel Grid.Row="2" Grid.Column="2" Orientation="Horizontal" HorizontalAlignment="Right" VerticalAlignment="Center">
            <TextBlock x:Name="ValIran" Style="{StaticResource Val}" VerticalAlignment="Center" Margin="0,0,10,0"/>
            <CheckBox x:Name="ChkIran" Style="{StaticResource Switch}" ToolTip="For VPNs in TUN mode: Iranian sites go directly through your normal internet instead of the VPN." VerticalAlignment="Center"/>
          </StackPanel>
          <TextBlock x:Name="ValList"  Grid.Row="3" Grid.Column="2" Style="{StaticResource Val}" VerticalAlignment="Center" Margin="12,0,0,0"/>
          <TextBlock x:Name="ValGuard" Grid.Row="4" Grid.Column="2" Style="{StaticResource Val}" VerticalAlignment="Center" Margin="12,0,0,0"/>
        </Grid>
      </Border>

      <UniformGrid Columns="3" Margin="0,10,0,0">
        <Button x:Name="BtnTest"    Style="{StaticResource Btn}" ToolTip="Checks for leaks: foreign traffic without VPN, DNS, WebRTC, IPv6 and Iranian sites." Margin="0,0,5,0" Content="Leak test"/>
        <Button x:Name="BtnPreview" Style="{StaticResource Btn}" ToolTip="Shows what turning on will do. Changes nothing." Margin="5,0,5,0" Content="Preview"/>
        <Button x:Name="BtnRefresh" Style="{StaticResource Btn}" ToolTip="Finds newly installed VPN programs, updates the Iran IP list and re-applies the direct sites." Margin="5,0,0,0" Content="Refresh"/>
      </UniformGrid>



      <StackPanel Orientation="Horizontal" HorizontalAlignment="Center" Margin="0,14,0,0">
        <Button x:Name="BtnLog" Style="{StaticResource Link}" ToolTip="Opens the activity log." Content="Log"/>
        <Button x:Name="BtnServers" Style="{StaticResource Link}" ToolTip="Optional: servers to allow without allowing a whole program (Windows built-in VPN, a SOCKS5 proxy set in a browser)." Content="Allowed servers"/>
        <Button x:Name="BtnDirect" Style="{StaticResource Link}" ToolTip="Sites that go out through your normal internet, not the VPN (like Iranian sites). Best with TUN-mode VPNs." Content="Direct sites"/>
        <Button x:Name="BtnUninstall" Style="{StaticResource Link}" ToolTip="Removes the tool and everything it changed." Content="Uninstall"/>
      </StackPanel>
      <TextBlock x:Name="Footer" HorizontalAlignment="Center" FontSize="11" Foreground="$($T.Off)" Margin="0,10,0,0"/>
    </StackPanel>

    <!-- overlay: dialogs + busy -->
    <Border x:Name="Overlay" Grid.RowSpan="2" Background="#E60E1014" CornerRadius="18" Visibility="Collapsed">
      <Border Background="$($T.Surface)" CornerRadius="14" Margin="22" Padding="20" VerticalAlignment="Center" BorderBrush="$($T.Line)" BorderThickness="1">
        <StackPanel>
          <TextBlock x:Name="OvTitle" FontSize="16" FontWeight="SemiBold" TextWrapping="Wrap"/>
          <ProgressBar x:Name="OvBusy" IsIndeterminate="True" Height="3" Margin="0,14,0,0" Foreground="$($T.Accent)" Background="$($T.Line)" BorderThickness="0"/>
          <TextBlock x:Name="OvBody" FontSize="12.5" Foreground="$($T.Muted)" TextWrapping="Wrap" Margin="0,10,0,0"/>
          <ScrollViewer x:Name="OvScroll" MaxHeight="330" Margin="0,10,-14,0" Style="{StaticResource Scroll}" Visibility="Collapsed">
            <TextBox x:Name="OvMono" FontFamily="Consolas" FontSize="11" IsReadOnly="True" Background="Transparent" Foreground="$($T.Text)" BorderThickness="0" TextWrapping="Wrap" Margin="0,0,14,0"/>
          </ScrollViewer>
          <ScrollViewer x:Name="OvListScroll" MaxHeight="400" Margin="0,10,-14,0" Style="{StaticResource Scroll}" Visibility="Collapsed">
            <StackPanel x:Name="OvList" Margin="0,0,14,0"/>
          </ScrollViewer>
          <UniformGrid x:Name="OvButtons" Columns="2" Margin="0,16,0,0">
            <Button x:Name="OvYes" Style="{StaticResource Btn}" Margin="0,0,5,0"/>
            <Button x:Name="OvNo" Style="{StaticResource Btn}" Margin="5,0,0,0"/>
          </UniformGrid>
        </StackPanel>
      </Border>
    </Border>
   </Grid>
  </Border>
</Window>
"@

$win = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
# Small screens / high DPI scaling: the whole window shrinks to fit the work area (no scrolling).
# IKS_GUI_FIT_HEIGHT simulates a small screen in tests.
function Fit-ToScreen {
    $wa = [Windows.SystemParameters]::WorkArea
    $avail = if ($env:IKS_GUI_FIT_HEIGHT) { [double]$env:IKS_GUI_FIT_HEIGHT } else { $wa.Height - 16 }
    $ui.Root.LayoutTransform = $null
    $win.UpdateLayout()
    $h = $win.ActualHeight
    if ($h -gt $avail -and $h -gt 0) {
        $k = [Math]::Max(0.55, $avail / $h)
        $ui.Root.LayoutTransform = New-Object Windows.Media.ScaleTransform($k, $k)
        $win.UpdateLayout()
    }
    if (-not $SelfTest) { $win.Top = $wa.Top + [Math]::Max(0, ($wa.Height - $win.ActualHeight) / 2); $win.Left = $wa.Left + ($wa.Width - $win.ActualWidth) / 2 }
}
$win.add_ContentRendered({ Fit-ToScreen })
$ui = @{}
$xaml.SelectNodes('//*[@*[local-name()="Name"]]') | ForEach-Object { $n = $_.GetAttribute('Name', 'http://schemas.microsoft.com/winfx/2006/xaml'); if ($n) { $ui[$n] = $win.FindName($n) } }
$conv = New-Object Windows.Media.BrushConverter
$ui.Ver.Text = "v$($script:IKS.Version)"; $ui.Footer.Text = "Made by $($script:IKS.Author)  $([char]0x00B7)  v$($script:IKS.Version)"   # one source: VERSION
function Brush([string]$Hex) { return $conv.ConvertFromString($Hex) }

# ---- background jobs --------------------------------------------------------
$script:Jobs = New-Object System.Collections.ArrayList
function Start-Job2([string]$Code, [scriptblock]$OnDone) {
    $ps = [PowerShell]::Create()
    $null = $ps.AddScript(". '$Entry'; $Code")
    $null = $script:Jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); Done = $OnDone })
}
$timer = New-Object Windows.Threading.DispatcherTimer
$timer.Interval = [TimeSpan]::FromMilliseconds(200)
$timer.add_Tick({
    foreach ($j in @($script:Jobs)) {
        if (-not $j.Handle.IsCompleted) { continue }
        $script:Jobs.Remove($j)
        $out = $null; $err = $null
        try { $out = $j.PS.EndInvoke($j.Handle) } catch { $err = $_.Exception.InnerException; if (-not $err) { $err = $_.Exception } ; $err = $err.Message }
        if (-not $err -and $j.PS.Streams.Error.Count) { $err = "$($j.PS.Streams.Error[0])" }
        $j.PS.Dispose()
        try { & $j.Done $out $err } catch { Show-Dialog 'Something went wrong' "$_" 'OK' $null $null $null }
    }
    if ($script:Deadline) { Update-Countdown }
    if ($script:ShowEvent.WaitOne(0)) { Show-Main }       # another launch asked us to come forward
})
$timer.Start()

# ---- tray icon + window lifetime ---------------------------------------------
# X hides to the tray; "Exit" in the tray menu quits. Protection never depends on the app running.
function New-IKSIcon([string]$Hex) {
    $bmp = New-Object Drawing.Bitmap 32, 32
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml($Hex))), 1, 1, 30, 30)
    $g.FillEllipse((New-Object Drawing.SolidBrush ([Drawing.ColorTranslator]::FromHtml($T.Surface))), 8, 8, 16, 16)
    $g.Dispose()
    return [Drawing.Icon]::FromHandle($bmp.GetHicon())
}
function Set-AppIcon([string]$Hex, [string]$Tip) {
    if ($script:IconColor -ne $Hex) {
        $ico = New-IKSIcon $Hex
        $script:Tray.Icon = $ico
        $win.Icon = [Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($ico.Handle, [Windows.Int32Rect]::Empty, [Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions())
        $script:IconColor = $Hex
    }
    $script:Tray.Text = $Tip.Substring(0, [Math]::Min(63, $Tip.Length))
}
function Show-Main {
    $win.Show()
    if ($win.WindowState -eq 'Minimized') { $win.WindowState = 'Normal' }
    $null = $win.Activate(); $win.Topmost = $true; $win.Topmost = $false
    Refresh-Status
}
function Hide-ToTray {
    $win.Hide()
    if (-not $script:TrayHinted) {
        $script:TrayHinted = $true
        $script:Tray.ShowBalloonTip(4000, 'Iran Kill Switch', 'Still running here. Protection keeps working even when this app is closed.', [Windows.Forms.ToolTipIcon]::Info)
    }
}
function Exit-App { $script:Exiting = $true; $script:Tray.Visible = $false; $script:Tray.Dispose(); $script:App.Shutdown() }

$script:Tray = New-Object Windows.Forms.NotifyIcon
$trayMenu = New-Object Windows.Forms.ContextMenuStrip
$null = $trayMenu.Items.Add('Open Iran Kill Switch', $null, { Show-Main })
$null = $trayMenu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$null = $trayMenu.Items.Add('Exit (protection keeps working)', $null, { Exit-App })
$script:Tray.ContextMenuStrip = $trayMenu
$script:Tray.add_MouseClick({ param($s, $e) if ($e.Button -eq [Windows.Forms.MouseButtons]::Left) { Show-Main } })
Set-AppIcon $T.Off 'Iran Kill Switch'
$script:Tray.Visible = -not $SelfTest
$win.add_Closing({ param($s, $e) if (-not $script:Exiting) { $e.Cancel = $true; Hide-ToTray } })   # Alt+F4 too

# ---- overlay helpers --------------------------------------------------------
function Show-Busy([string]$Title) {
    $ui.OvTitle.Text = $Title; $ui.OvBody.Text = ''; $ui.OvBusy.Visibility = 'Visible'
    $ui.OvButtons.Visibility = 'Collapsed'; $ui.OvScroll.Visibility = 'Collapsed'; $ui.OvListScroll.Visibility = 'Collapsed'
    $ui.Overlay.Visibility = 'Visible'
}
function Show-Dialog([string]$Title, [string]$Body, [string]$Yes, [scriptblock]$OnYes, [string]$No, [scriptblock]$OnNo, [string]$Mono = '') {
    $ui.OvTitle.Text = $Title; $ui.OvBody.Text = $Body; $ui.OvBusy.Visibility = 'Collapsed'
    $ui.OvBody.Visibility = $(if ($Body) { 'Visible' } else { 'Collapsed' })
    $ui.OvScroll.Visibility = $(if ($Mono) { 'Visible' } else { 'Collapsed' }); $ui.OvMono.Text = $Mono
    $ui.OvListScroll.Visibility = 'Collapsed'
    $ui.OvYes.Content = $Yes; $script:OnYes = $OnYes
    $ui.OvYes.Background = Brush $(if ($OnYes) { $T.Accent } else { $T.Surface2 }); $ui.OvYes.Foreground = Brush $(if ($OnYes) { '#0B1220' } else { $T.Text })
    if ($No) { $ui.OvNo.Content = $No; $ui.OvNo.Visibility = 'Visible'; $ui.OvButtons.Columns = 2 } else { $ui.OvNo.Visibility = 'Collapsed'; $ui.OvButtons.Columns = 1 }
    $script:OnNo = $OnNo
    $ui.OvButtons.Visibility = 'Visible'; $ui.Overlay.Visibility = 'Visible'
}
function Hide-Overlay { $ui.Overlay.Visibility = 'Collapsed'; $script:Deadline = $null }
function Test-Busy { return $ui.Overlay.Visibility -eq 'Visible' }     # buttons ignored while a dialog/job is shown
$ui.OvYes.add_Click({ $cb = $script:OnYes; Hide-Overlay; if ($cb) { & $cb } })
$ui.OvNo.add_Click({ $cb = $script:OnNo; Hide-Overlay; if ($cb) { & $cb } })

# ---- status rendering -------------------------------------------------------
$script:Status = $null
function Set-Dot($Dot, [string]$Color) { $Dot.Fill = Brush $Color }

# ---- ring switch effects ----------------------------------------------------------
# ON : the arc is "drawn" once around the ring, then the glow breathes slowly.
# OFF: static grey. Hover shows what a click will do.
function Get-RingHoverHint([bool]$Enabled) { if ($Enabled) { 'CLICK TO TURN OFF' } else { 'CLICK TO TURN ON' } }
$script:LastRingOn = $null
function Set-RingEffects([bool]$On, [string]$Color) {
    if ($SelfTest -or $script:LastRingOn -eq $On) { return }
    $script:LastRingOn = $On
    $op = [Windows.UIElement]::OpacityProperty
    if ($On) {
        # draw-in: a dash as long as the circle, offset animated to 0 (dash units = stroke widths)
        $units = [Math]::PI * ($ui.Ring.Width - $ui.RingArc.StrokeThickness) / $ui.RingArc.StrokeThickness
        $dc = New-Object Windows.Media.DoubleCollection; $dc.Add($units); $dc.Add($units)
        $ui.RingArc.StrokeDashArray = $dc
        $draw = New-Object Windows.Media.Animation.DoubleAnimation($units, 0, [Windows.Duration][TimeSpan]::FromMilliseconds(750))
        $draw.EasingFunction = New-Object Windows.Media.Animation.CubicEase -Property @{ EasingMode = 'EaseOut' }
        $draw.add_Completed({ $ui.RingArc.StrokeDashArray = $null })
        $ui.RingArc.BeginAnimation([Windows.Shapes.Shape]::StrokeDashOffsetProperty, $draw)
        $glow = New-Object Windows.Media.Animation.DoubleAnimation(0.10, 0.42, [Windows.Duration][TimeSpan]::FromSeconds(1.8))
        $glow.AutoReverse = $true; $glow.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
        $glow.EasingFunction = New-Object Windows.Media.Animation.SineEase -Property @{ EasingMode = 'EaseInOut' }
        $ui.RingGlow.BeginAnimation($op, $glow)
    } else {
        $ui.RingGlow.BeginAnimation($op, $null); $ui.RingGlow.Opacity = 0.14
        $ui.RingArc.BeginAnimation([Windows.Shapes.Shape]::StrokeDashOffsetProperty, $null); $ui.RingArc.StrokeDashArray = $null
    }
}
$ui.RingBtn.add_MouseEnter({ if ($script:Status) { $ui.RingHint.Text = Get-RingHoverHint ([bool]$script:Status.Enabled) } })
$ui.RingBtn.add_MouseLeave({ if ($script:RingHintIdle) { $ui.RingHint.Text = $script:RingHintIdle } })

# Footer: author + version, or a download link when GitHub has a newer release
function Set-Footer {
    if ($script:Update) {
        $ui.Footer.Text = "Update available: v$($script:Update.Version)  $([char]0x00B7)  click to download"
        $ui.Footer.Foreground = Brush $T.Green; $ui.Footer.Cursor = [Windows.Input.Cursors]::Hand
        $ui.Footer.ToolTip = "You have v$($script:IKS.Version). Opens the download page."
    } else {
        $ui.Footer.Text = "Made by $($script:IKS.Author)  $([char]0x00B7)  v$($script:IKS.Version)"
    }
}
function Start-UpdateCheck {
    if ($SelfTest) { return }
    Start-Job2 'Get-IKSUpdateInfo' { param($o, $e) if (-not $e -and $o -and $o[0]) { $script:Update = $o[0]; Set-Footer } }
}
$ui.Footer.add_MouseLeftButtonUp({ if ($script:Update) { try { Start-Process $script:Update.Url } catch { } } })

function Render-Status($s) {
    $script:Status = $s
    $ui.Ver.Text = "v$($s.Version)"
    Set-Footer
    if ($s.Enabled -and $s.RevertPending) { $c = $T.Amber; $ring = 'ON'; $hint = 'NOT CONFIRMED'; $h = 'Waiting for your confirmation'; $sub = 'Protection will be undone automatically unless you confirm it works.' }
    elseif ($s.Enabled -and $s.Healthy) {
        $c = $T.Green; $ring = 'ON'; $hint = 'PROTECTED'; $h = 'You are protected'
        $sub = if ($s.VpnMode -eq 'none') { 'VPN is off: foreign sites are blocked, Iranian sites work normally.' } else { 'Foreign traffic only through the VPN. Iranian sites go direct.' }
    } elseif ($s.Enabled) { $c = $T.Amber; $ring = 'ON'; $hint = 'ATTENTION'; $h = 'Needs attention'; $sub = $s.Problems[0] }
    else { $c = $T.Off; $ring = 'OFF'; $hint = 'CLICK TO TURN ON'; $h = 'Kill switch is off'; $sub = 'If the VPN drops, foreign traffic leaves with your real IP.' }
    if (-not $s.Enabled -and $s.Problems) { $sub = $s.Problems[0] }
    $ui.RingArc.Stroke = Brush $c; $ui.RingGlow.Stroke = Brush $c; $ui.RingIcon.Foreground = Brush $c
    $ui.RingText.Text = $ring; $ui.Headline.Text = $h; $ui.Sub.Text = $sub
    $script:RingHintIdle = $hint
    $ui.RingHint.Text = $(if ($ui.RingBtn.IsMouseOver) { Get-RingHoverHint $s.Enabled } else { $hint })
    Set-RingEffects ([bool]$s.Enabled) $c
    if ($script:ProtOn -ne [bool]$s.Enabled) { $script:ProtOn = [bool]$s.Enabled; Sync-Bypass }   # ON/OFF changed: apply now
    Set-AppIcon $c "Iran Kill Switch - $ring ($($hint.ToLower()))"
    # A VPN app started a helper program (e.g. MobaXterm -> MobaRTE.exe): allow it right away
    if (-not $SelfTest -and $s.Enabled -and $s.PendingChildren -gt 0 -and -not $script:AutoSyncing -and -not (Test-Busy)) {
        $script:AutoSyncing = $true
        Start-Job2 'Invoke-IKSSync -NoScan' { param($o, $e) $script:AutoSyncing = $false; Refresh-Status }
    }

    $clients = (@($s.VpnApps | Where-Object Running | ForEach-Object { $_.Name } | Where-Object { $_ -notmatch '(?i)service|svc|cli$' }) | Select-Object -Unique -First 2) -join ', '
    switch ($s.VpnMode) {
        'tun'   { $ui.ValVpn.Text = "$clients - TUN $($s.Tunnel)".Trim(' -'); Set-Dot $ui.DotVpn $T.Green }
        'proxy' {
            if ($s.SystemProxy -eq $false) { $ui.ValVpn.Text = "$clients - proxy, Windows proxy OFF"; Set-Dot $ui.DotVpn $T.Amber }   # browsers go direct -> blocked
            else { $ui.ValVpn.Text = "$clients - proxy $($s.Proxy -replace 'http://', '')"; Set-Dot $ui.DotVpn $T.Green }
        }
        default { $ui.ValVpn.Text = $(if ($clients) { "$clients - not connected" } else { 'Not connected' }); Set-Dot $ui.DotVpn $T.Off }
    }
    $apps = @($s.VpnApps | Where-Object Exists)
    $ui.ValApps.Text = $(if ($apps) { "$($apps.Count) allowed" } else { 'none found' })
    Set-Dot $ui.DotApps $(if ($apps) { $T.Green } else { $T.Amber })
    $script:SyncingIran = $true; $ui.ChkIran.IsChecked = [bool]$s.IranDirect; $script:SyncingIran = $false
    $ui.ValIran.Text = $(if (-not $s.IranDirect) { 'off' } elseif ($s.Enabled -and $s.IranRoutes) { "$($s.IranRoutes) routes" } elseif ($s.Enabled) { 'no network' } else { 'on with protection' }) +
                       $(if ($s.DirectSites) { " + $($s.DirectSites) direct site$(if ($s.DirectSites -gt 1) { 's' })" } else { '' })
    Set-Dot $ui.DotIran $(if ($s.IranDirect -and $s.Enabled -and $s.IranRoutes) { $T.Green } else { $T.Off })
    $ui.ValList.Text = '{0:N0} ranges - {1}' -f $s.IranRanges, $(if ($s.ListUpdated) { $s.ListUpdated.Substring(0, [Math]::Min(10, $s.ListUpdated.Length)) } else { 'unknown' })
    Set-Dot $ui.DotList $(if ($s.IranRanges -gt 300) { $T.Green } else { $T.Red })
    $ui.ValGuard.Text = $(if ($s.GuardInstalled) { if ($s.GuardLastRun) { "Active - checked $($s.GuardLastRun.Substring(11))" } else { 'Active' } } else { 'Not installed' })
    Set-Dot $ui.DotGuard $(if ($s.GuardInstalled) { $T.Green } else { $T.Red })
}

# Refresh-Status { callback }: callback runs after the NEW status is on screen
$script:StatusBusy = $false; $script:StatusAgain = $false; $script:StatusThen = @()
function Refresh-Status([scriptblock]$Then) {
    if ($Then) { $script:StatusThen += , $Then }
    if ($script:StatusBusy) { $script:StatusAgain = $true; return }
    $script:StatusBusy = $true
    Start-Job2 'Get-IKSStatus' {
        param($o, $e)
        $script:StatusBusy = $false
        if (-not $e -and $o) { Render-Status $o[0] }
        if ($script:StatusAgain) { $script:StatusAgain = $false; Refresh-Status; return }
        $cbs = $script:StatusThen; $script:StatusThen = @()
        foreach ($cb in $cbs) { & $cb }
    }
}

# Test rows go into the overlay card (the main window never grows)
function Fill-Tests($rows) {
    $ui.OvList.Children.Clear()
    $rows = @($rows)
    $p = @($rows | Where-Object { $_.Result -eq 'PASS' }).Count; $f = @($rows | Where-Object { $_.Result -eq 'FAIL' }).Count
    foreach ($r in $rows) {
        $g = New-Object Windows.Controls.Grid; $g.Margin = '0,0,0,4'
        $c0 = New-Object Windows.Controls.ColumnDefinition; $c0.Width = '22'; $g.ColumnDefinitions.Add($c0)
        $g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
        $icon = New-Object Windows.Controls.TextBlock; $icon.FontFamily = 'Segoe MDL2 Assets'; $icon.FontSize = 11; $icon.Margin = '0,3,0,0'
        switch ($r.Result) { 'PASS' { $icon.Text = [char]0xE73E; $icon.Foreground = Brush $T.Green } 'FAIL' { $icon.Text = [char]0xE711; $icon.Foreground = Brush $T.Red } default { $icon.Text = [char]0xE738; $icon.Foreground = Brush $T.Muted } }
        $sp = New-Object Windows.Controls.StackPanel; [Windows.Controls.Grid]::SetColumn($sp, 1)
        $a = New-Object Windows.Controls.TextBlock; $a.Text = $r.Test; $a.FontSize = 12.5
        $b = New-Object Windows.Controls.TextBlock; $b.Text = $r.Detail; $b.FontSize = 10.5; $b.Foreground = Brush $T.Muted; $b.TextWrapping = 'Wrap'
        $null = $sp.Children.Add($a); $null = $sp.Children.Add($b)
        $null = $g.Children.Add($icon); $null = $g.Children.Add($sp)
        $null = $ui.OvList.Children.Add($g)
    }
    $sum = if ($f) { "$f problem(s) found - $p of $($rows.Count) checks passed." } else { "All good - $p of $($rows.Count) checks passed." }
    return @{ Pass = $p; Fail = $f; Total = $rows.Count; Summary = $sum }
}
function Show-ListCard { $ui.OvListScroll.Visibility = 'Visible' }

# ---- flows ------------------------------------------------------------------
function Fail-Dialog([string]$What, $Err) { Write-IKSLog "GUI: $What - $Err" 'ERROR'; Refresh-Status; Show-Dialog $What "$Err" 'OK' $null $null $null }

function Start-Enable {
    Show-Busy 'Turning protection on...'
    $script:EnableStarted = Get-Date
    Start-Job2 'Invoke-IKSEnable -WithRevert' {
        param($o, $e)
        if ($e) { Fail-Dialog 'Could not turn on' $e; return }
        Show-Busy 'Checking that everything works...'
        Start-Job2 'Invoke-IKSTest' {
            param($o2, $e2)
            Refresh-Status
            $sum = if ($e2) { $ui.OvList.Children.Clear(); @{ Fail = 1; Pass = 0; Total = 0 } } else { Fill-Tests $o2 }
            $script:TestBody = if ($sum.Fail) { "$($sum.Fail) check(s) failed. If Iranian sites do not open, press Undo." }
                               else { "All $($sum.Pass) checks passed. Open an Iranian site and a foreign site to be sure." }
            # The checks may have used most of the 2 minutes: give the user a full window again
            Start-Job2 'Reset-IKSRevertTimer' {
                param($o4, $e4)
                $next = $(if ($o4) { $o4[0] } else { $null })
                if ($e4 -or -not ($next -is [datetime])) {
                    if (-not $e4) { Show-Busy 'Undoing (not confirmed)...'; Wait-Revert; return }   # already undone
                    $next = $script:EnableStarted.AddSeconds($script:IKS.RevertSeconds)              # keep the old timer
                }
                $script:EnableStarted = $next.AddSeconds(-$script:IKS.RevertSeconds)
                $script:Deadline = $next.AddSeconds(-5)
                Show-Dialog 'Is everything working?' $script:TestBody 'Keep protection' {
                    $script:Deadline = $null
                    Show-Busy 'Saving...'
                    Start-Job2 'Confirm-IKSKeep' { param($o3, $e3) if ($e3) { Fail-Dialog 'Could not confirm' $e3 } else { Refresh-Status { Hide-Overlay } } }
                } 'Undo now' { Start-Disable }
                Show-ListCard
                Update-Countdown
            }
        }
    }
}

function Update-Countdown {
    $left = [int]($script:Deadline - (Get-Date)).TotalSeconds
    if ($left -le 0) { Hide-Overlay; Show-Busy 'Undoing (not confirmed)...'; Wait-Revert; return }
    $ui.OvTitle.Text = 'Is everything working?  Auto-undo in {0}:{1:00}' -f [int][Math]::Floor($left / 60), ($left % 60)
}

# Revert task fires a few seconds after the countdown; poll status until OFF
function Wait-Revert {
    Start-Job2 'Start-Sleep 8; Get-IKSStatus' {
        param($o, $e)
        if ($o -and -not $o[0].Enabled) { Hide-Overlay; Render-Status $o[0]; Show-Dialog 'Protection was undone' 'You did not confirm, so all changes were rolled back automatically.' 'OK' $null $null $null }
        elseif ((Get-Date) -gt $script:EnableStarted.AddSeconds($script:IKS.RevertSeconds + 60)) { Start-Disable }
        else { Wait-Revert }
    }
}

function Start-Disable {
    Show-Busy 'Turning protection off...'
    Start-Job2 'Invoke-IKSDisable' {
        param($o, $e)
        if ($e) { Fail-Dialog 'Could not turn off' "$e`n`nUse Start menu > Iran Kill Switch > Emergency OFF." }
        else { Refresh-Status { Hide-Overlay } }      # keep the lock until the new state is shown
    }
}

# ---- wire up ------------------------------------------------------------------
$ui.TitleBar.add_MouseLeftButtonDown({ $win.DragMove() })
$ui.BtnClose.add_Click({ Hide-ToTray })
$ui.BtnMin.add_Click({ $win.WindowState = 'Minimized' })

$toggle = {
    if (-not $script:Status -or (Test-Busy)) { return }
    if ($script:Status.Enabled) { Start-Disable; return }
    Show-Dialog 'Turn on protection?' ("Foreign sites will work only through your VPN. Iranian sites keep working directly.`n`n" +
        "Safety net: if you do not confirm within 2 minutes, everything is undone automatically.") 'Turn ON' { Start-Enable } 'Cancel' $null
}
$ui.RingBtn.add_Click($toggle)
# The ring is the single on/off control (see Set-RingEffects for its animations).

$ui.BtnTest.add_Click({
    if (Test-Busy) { return }
    Show-Busy 'Running leak tests...'
    Start-Job2 'Invoke-IKSTest' {
        param($o, $e)
        if ($e) { Fail-Dialog 'Test failed to run' $e; return }
        $sum = Fill-Tests $o
        Show-Dialog 'Leak test' $sum.Summary 'Close' $null $null $null
        Show-ListCard
    }
})
$ui.BtnPreview.add_Click({
    if (Test-Busy) { return }
    Show-Busy 'Building preview (nothing will be changed)...'
    Start-Job2 'Invoke-IKSPreview' { param($o, $e) if ($e) { Fail-Dialog 'Preview failed' $e } else { Show-Dialog 'What "Turn ON" will do' '' 'Close' $null $null $null ("$($o -join "`r`n")") } }
})
function Sync-Bypass { if ($SelfTest) { return }; try { $m = Sync-IKSProxyBypass ([bool]$script:ProtOn); if ($m) { Write-IKSLog "Proxy bypass: $m" } } catch { } }
$script:ProtOn = $null
$ui.BtnRefresh.add_Click({
    if (Test-Busy) { return }
    Show-Busy 'Detecting VPN apps and updating the Iran list...'
    Sync-Bypass
    Start-Job2 'Invoke-IKSSync' { param($o, $e) if ($e) { Fail-Dialog 'Refresh failed' $e } else { Refresh-Status { Hide-Overlay } } }
})
$ui.BtnLog.add_Click({ if (Test-Path $script:IKS.LogFile) { Start-Process notepad.exe $script:IKS.LogFile } })
# Direct sites: edit in Notepad; when Notepad closes, a background sync applies the list
$ui.BtnDirect.add_Click({
    if ($script:DirectEditing) { return }
    New-IKSDirectFile
    $script:DirectEditing = $true
    Start-Job2 "Start-Process notepad.exe -ArgumentList ('`"' + `$script:IKS.DirectFile + '`"') -Wait; Invoke-IKSSync -NoScan" {
        param($o, $e)
        $script:DirectEditing = $false
        if ($e) { Fail-Dialog 'Direct sites' $e } else { Sync-Bypass; Refresh-Status }
    }
})
$ui.BtnServers.add_Click({ Initialize-IKSState; if (-not (Test-Path $script:IKS.EndpointsFile)) { '' | Set-Content $script:IKS.EndpointsFile }; Start-Process notepad.exe $script:IKS.EndpointsFile })

# ---- VPN apps dialog -----------------------------------------------------------
function Show-Apps {
    $ui.OvList.Children.Clear()
    $apps = @($script:Status.VpnApps | Sort-Object Name)
    if (-not $apps) {
        $t = New-Object Windows.Controls.TextBlock; $t.Text = 'No VPN program found yet. Start your VPN app and press Refresh, or add it below.'
        $t.TextWrapping = 'Wrap'; $t.Foreground = Brush $T.Muted; $null = $ui.OvList.Children.Add($t)
    }
    foreach ($a in $apps) {
        $g = New-Object Windows.Controls.Grid; $g.Margin = '0,0,0,8'
        $g.ColumnDefinitions.Add((New-Object Windows.Controls.ColumnDefinition))
        $c1 = New-Object Windows.Controls.ColumnDefinition; $c1.Width = 'Auto'; $g.ColumnDefinitions.Add($c1)
        $sp = New-Object Windows.Controls.StackPanel
        $n = New-Object Windows.Controls.TextBlock; $n.FontSize = 13
        $n.Text = "$($a.Name)$(if ($a.Running) { '   ' + [char]0x25CF + ' running' })$(if ($a.Source -eq 'user') { '   (added by you)' })"
        if (-not $a.Exists) { $n.Text += '   (missing)'; $n.Foreground = Brush $T.Muted }
        $p = New-Object Windows.Controls.TextBlock; $p.Text = $a.Path; $p.FontSize = 10.5; $p.Foreground = Brush $T.Muted; $p.TextTrimming = 'CharacterEllipsis'
        $null = $sp.Children.Add($n); $null = $sp.Children.Add($p)
        $rm = New-Object Windows.Controls.Button; $rm.Content = 'Remove'; $rm.Style = $win.FindResource('Link'); $rm.Tag = $a.Path
        [Windows.Controls.Grid]::SetColumn($rm, 1); $rm.VerticalAlignment = 'Center'
        $rm.add_Click({
            param($sender, $e)
            $path = $sender.Tag
            Show-Busy 'Removing VPN app...'
            Start-Job2 ("Remove-IKSVpnApp '{0}'" -f $path.Replace("'", "''")) { param($o, $e) if ($e) { Fail-Dialog 'Could not remove' $e } else { Refresh-Status { Show-Apps } } }
        })
        $null = $g.Children.Add($sp); $null = $g.Children.Add($rm)
        $null = $ui.OvList.Children.Add($g)
    }
    Show-Dialog 'VPN apps allowed through the kill switch' 'These programs may connect anywhere; everything else reaches foreign sites only through the tunnel. If your VPN cannot connect: open it, press Refresh, or add its program with Add app.' 'Add app...' {
        $dlg = New-Object Microsoft.Win32.OpenFileDialog
        $dlg.Title = 'Choose the VPN program (.exe)'; $dlg.Filter = 'Programs (*.exe)|*.exe'
        if ($dlg.ShowDialog($win)) {
            Show-Busy 'Adding VPN app...'
            Start-Job2 ("Add-IKSVpnApp '{0}'" -f $dlg.FileName.Replace("'", "''")) { param($o, $e) if ($e) { Fail-Dialog 'Could not add' $e } else { Refresh-Status { Show-Apps } } }
        } else { Show-Apps }
    } 'Close' $null
    $ui.OvListScroll.Visibility = 'Visible'
}
$ui.BtnApps.add_Click({ if (-not $script:Status -or (Test-Busy)) { return }; Show-Apps })

# ---- Iran direct switch ----------------------------------------------------------
$ui.ChkIran.add_Click({
    if ($script:SyncingIran) { return }
    if (Test-Busy) { $ui.ChkIran.IsChecked = -not $ui.ChkIran.IsChecked; return }
    $on = [bool]$ui.ChkIran.IsChecked
    Show-Busy $(if ($on) { 'Adding direct routes for Iran...' } else { 'Removing Iran routes...' })
    Start-Job2 "Set-IKSIranDirect `$$on" { param($o, $e) if ($e) { Fail-Dialog 'Iran direct' $e } else { Refresh-Status { Hide-Overlay } } }
})
$ui.BtnUninstall.add_Click({
    if (Test-Busy) { return }
    Show-Dialog 'Uninstall Iran Kill Switch?' 'All rules, tasks and shortcuts are removed and Windows Firewall goes back to how it was. A firewall backup is kept in C:\ProgramData\IranKillSwitch-backup.' 'Uninstall' {
        Show-Busy 'Uninstalling...'
        Start-Job2 'Invoke-IKSUninstall' { param($o, $e) Show-Dialog $(if ($e) { 'Uninstall problem' } else { 'Uninstalled' }) "$(if ($e) { $e } else { $o })" 'Close' { Exit-App } $null $null }
    } 'Cancel' $null
})

if ($SelfTest) {
    # Developer check: render sample states to a PNG off-screen, then exit
    $win.Left = -20000; $win.ShowInTaskbar = $false
    $win.add_ContentRendered({
        try {
            Render-Status ([pscustomobject]@{ Version = $script:IKS.Version; Enabled = $true; Healthy = $true; RevertPending = $false; Problems = @(); VpnMode = 'tun'
                VpnApps = @([pscustomobject]@{ Name = 'Hiddify'; Path = 'c:\program files\hiddify\hiddify.exe'; Source = 'auto'; Exists = $true; Running = $true },
                            [pscustomobject]@{ Name = 'HD-Player'; Path = 'c:\program files\bluestacks_nxt\hd-player.exe'; Source = 'auto'; Exists = $true; Running = $false })
                Author = 'Mansoor'; IranDirect = $true; IranRoutes = 1747; Tunnel = 'tun0 172.19.0.1'; Proxy = ''; IranRanges = 1602
                ListUpdated = '2026-11-12 09:43'; GuardInstalled = $true; GuardLastRun = '2026-11-12 10:05' })
            # IKS_GUI_SELFTEST_VIEW: main (default) | apps | tests
            switch ($env:IKS_GUI_SELFTEST_VIEW) {
                'apps' {
                    $script:Status.VpnApps = @(
                        foreach ($a in @(@('Hiddify', 'c:\program files\hiddify\hiddify.exe', 'auto', $true), @('HiddifyCli', 'c:\program files\hiddify\hiddifycli.exe', 'auto', $false),
                                         @('AmneziaVPN', 'c:\program files\amneziavpn\amneziavpn.exe', 'auto', $false), @('amneziawg', 'c:\program files\amneziawg\amneziawg.exe', 'auto', $false),
                                         @('HD-Player', 'c:\program files\bluestacks_nxt\hd-player.exe', 'auto', $false), @('SocksTunnel', 'c:\tools\sockstunnel\sockstunnel.exe', 'user', $true))) {
                            [pscustomobject]@{ Name = $a[0]; Path = $a[1]; Source = $a[2]; Exists = $true; Running = $a[3] } })
                    Show-Apps
                }
                'tests' {
                    $sum = Fill-Tests @(
                        [pscustomobject]@{ Test = 'Kill switch active'; Result = 'PASS'; Detail = '58 WFP filters active' },
                        [pscustomobject]@{ Test = 'VPN programs allowed'; Result = 'PASS'; Detail = 'Hiddify (running), AmneziaVPN, HD-Player' },
                        [pscustomobject]@{ Test = 'Foreign traffic blocked when VPN is down'; Result = 'PASS'; Detail = 'Wi-Fi 192.168.1.100: 1.1.1.1 blocked by firewall' },
                        [pscustomobject]@{ Test = 'Iranian sites work directly'; Result = 'PASS'; Detail = 'www.aparat.com reached directly via Wi-Fi' },
                        [pscustomobject]@{ Test = 'DNS leak'; Result = 'PASS'; Detail = 'foreign DNS 8.8.8.8 outside VPN: no answer' },
                        [pscustomobject]@{ Test = 'WebRTC leak'; Result = 'PASS'; Detail = 'STUN outside VPN: no answer' },
                        [pscustomobject]@{ Test = 'IPv6 leak'; Result = 'PASS'; Detail = 'no public IPv6 on the real adapter' },
                        [pscustomobject]@{ Test = 'Iranian sites bypass the VPN (TUN)'; Result = 'PASS'; Detail = 'www.aparat.com goes out via Wi-Fi, not the tunnel' },
                        [pscustomobject]@{ Test = 'Internet through VPN'; Result = 'PASS'; Detail = 'Foreign sites see 203.0.113.10 (tun mode)' })
                    Show-Dialog 'Leak test' $sum.Summary 'Close' $null $null $null
                    Show-ListCard
                }
            }
            $win.UpdateLayout()
            $bmp = New-Object Windows.Media.Imaging.RenderTargetBitmap ([int]$win.ActualWidth), ([int]$win.ActualHeight), 96, 96, ([Windows.Media.PixelFormats]::Pbgra32)
            $bmp.Render($win.Content)
            $enc = New-Object Windows.Media.Imaging.PngBitmapEncoder; $enc.Frames.Add([Windows.Media.Imaging.BitmapFrame]::Create($bmp))
            $fs = [IO.File]::Create($SelfTest); $enc.Save($fs); $fs.Close()
            [Console]::Out.WriteLine('GUI-SELFTEST-OK')
        } catch { [Console]::Out.WriteLine("GUI-SELFTEST-FAIL: $_") }
        Exit-App
    })
} else {
$win.add_Loaded({
    $installed = Test-Path (Join-Path $script:IKS.InstallDir 'IKS.ps1')
    if (-not $installed) {
        Show-Dialog 'Install Iran Kill Switch?' ("It will be installed to $($script:IKS.InstallDir) with a desktop shortcut and a small background guard. " +
            'Protection stays OFF until you turn it on.') 'Install' {
            Show-Busy 'Installing...'
            Start-Job2 'Invoke-IKSInstall' {
                param($o, $e)
                if ($e) { Fail-Dialog 'Install failed' $e; return }
                Start-Process (Join-Path $script:IKS.InstallDir 'IranKillSwitch.exe')
                Exit-App
            }
        } 'Not now' { Exit-App }
        return
    }
    Refresh-Status
})
}
$poll =New-Object Windows.Threading.DispatcherTimer
$poll.Interval = [TimeSpan]::FromSeconds(15)
$script:PollN = 0
$poll.add_Tick({
    $script:PollN++
    # every 15 s (also in the tray): keeps the tray colour current and lets helpers of VPN apps through quickly
    if (-not (Test-Busy)) { Refresh-Status }
    if ($script:PollN % 1440 -eq 0) { Start-UpdateCheck }      # every 6 hours while the app runs
})
$poll.Start()
Start-UpdateCheck

# Proxy-mode VPNs: keep the direct sites in the Windows "no proxy" list (the VPN app may rewrite it).
# Runs on ON/OFF change, Refresh, Direct sites save, and once an hour (~8 ms each)
$bypass = New-Object Windows.Threading.DispatcherTimer
$bypass.Interval = [TimeSpan]::FromHours(1)
$bypass.add_Tick({ Sync-Bypass })
if (-not $SelfTest) { $bypass.Start() }

$script:App = New-Object Windows.Application
$script:App.ShutdownMode = [Windows.ShutdownMode]::OnExplicitShutdown
# Never die silently: any error inside a UI event is logged and shown, the app keeps running
$script:App.add_DispatcherUnhandledException({
    param($s, $e)
    $e.Handled = $true
    $msg = "$($e.Exception.Message)"
    if ($e.Exception.InnerException) { $msg += " / $($e.Exception.InnerException.Message)" }
    Write-IKSLog "GUI error: $msg" 'ERROR'
    [Console]::Error.WriteLine("GUI error: $msg")
    try { Show-Dialog 'Something went wrong' $msg 'OK' $null $null $null } catch { }
})
$null = $script:App.Run($win)
$timer.Stop(); $poll.Stop(); $bypass.Stop()
if (-not $SelfTest) { $script:Single.ReleaseMutex() }
