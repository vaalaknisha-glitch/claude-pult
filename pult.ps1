# ===================== Пульт Claude v6 =====================
# Показывает команды из папки zadaniya и выполняет только одобренные пользователем.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -Namespace Pult -Name Native -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(System.IntPtr hwnd, int attr, ref int val, int size);
'@
[void][Pult.Native]::SetProcessDPIAware()
Add-Type -ReferencedAssemblies System.Windows.Forms,System.Drawing -TypeDefinition @'
namespace Pult {
  public class QuietForm : System.Windows.Forms.Form {
    protected override bool ShowWithoutActivation { get { return true; } }
    protected override System.Windows.Forms.CreateParams CreateParams {
      get { var cp = base.CreateParams; cp.ExStyle |= 0x08000000 | 0x00000080 | 0x00000008; return cp; }
    }
  }
}
'@
[System.Windows.Forms.Application]::EnableVisualStyles()
# Никаких системных окон с ошибками: всё пишется в журнал
[System.Windows.Forms.Application]::SetUnhandledExceptionMode([System.Windows.Forms.UnhandledExceptionMode]::CatchException)
[System.Windows.Forms.Application]::add_ThreadException({ param($s,$e) try { Log-Error 'ui' $e.Exception.Message } catch {} })

$mutex = New-Object System.Threading.Mutex($false, 'Global\ClaudePultMutex')
try { $got = $mutex.WaitOne(0) } catch [System.Threading.AbandonedMutexException] { $got = $true }
if (-not $got) { exit }

$script:AppDir  = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:Root    = Join-Path $env:USERPROFILE 'Downloads\ClaudePult'
$script:Inbox   = Join-Path $script:Root 'zadaniya'
$script:Outbox  = Join-Path $script:Root 'otvety'
$script:Done    = Join-Path $script:Root 'arhiv'
$script:WorkDir = Join-Path $env:LOCALAPPDATA 'ClaudePult\work'
$script:ErrLog  = Join-Path $script:Root 'oshibki_pulta.log'
$script:SetPath = Join-Path $env:LOCALAPPDATA 'ClaudePult\settings.json'
$script:Startup = Join-Path ([Environment]::GetFolderPath('Startup')) 'ClaudePult.vbs'
foreach ($d in $script:Inbox,$script:Outbox,$script:Done,$script:WorkDir) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Log-Error($where, $err) {
  try { [IO.File]::AppendAllText($script:ErrLog, ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + " [$where] " + $err + "`r`n"), $script:Utf8NoBom) } catch {}
}

# --- Масштаб и палитра ---
$g0 = [System.Drawing.Graphics]::FromHwnd([IntPtr]::Zero); $script:Sc = $g0.DpiX / 96.0; $g0.Dispose()
function S([double]$v) { [int][math]::Round($v * $script:Sc) }
function C($hex) { [System.Drawing.ColorTranslator]::FromHtml($hex) }
$script:cBg = C '#1C1C1F'; $script:cCard = C '#111113'; $script:cText = C '#F2F2F5'; $script:cMuted = C '#8E8E96'
$script:cAccent = C '#3B7BFF'; $script:cAccentH = C '#5A92FF'; $script:cGray = C '#2C2C31'; $script:cGrayH = C '#3A3A40'
$script:cCode = C '#B9E6C3'

# --- Настройки ---
$script:Set = @{ Volume = 20; Sound = $true; ResultToast = $false; Expand = $false }
if (Test-Path $script:SetPath) {
  try { $j = Get-Content -Raw -Encoding UTF8 $script:SetPath | ConvertFrom-Json; foreach ($k in @($script:Set.Keys)) { if ($null -ne $j.$k) { $script:Set[$k] = $j.$k } } } catch { Log-Error 'settings' $_ }
}
function Save-Settings { try { [IO.File]::WriteAllText($script:SetPath, ($script:Set | ConvertTo-Json), $script:Utf8NoBom) } catch { Log-Error 'save' $_ } }

# --- Ресурсы ---
$IconPath = Join-Path $script:AppDir 'pult.ico'; $PngPath = Join-Path $script:AppDir 'pult.png'; $WavPath = Join-Path $script:AppDir 'pult.wav'
$script:AppIcon = if (Test-Path $IconPath) { New-Object System.Drawing.Icon($IconPath) } else { [System.Drawing.SystemIcons]::Shield }
$AlertPath = Join-Path $script:AppDir 'pult_alert.ico'
$script:AlertIcon = if (Test-Path $AlertPath) { New-Object System.Drawing.Icon($AlertPath) } else { $script:AppIcon }
$script:Logo    = if (Test-Path $PngPath) { [System.Drawing.Image]::FromFile($PngPath) } else { $null }
$script:WavScaled = $null; $script:WavVol = -1
$script:WavBytes = if (Test-Path $WavPath) { [IO.File]::ReadAllBytes($WavPath) } else { $null }
$script:Player = $null

# Громкость: ползунок 0..100, кривая квадратичная (на слух равномернее). 20 ≈ тихий «пик».
function Play-Ding([switch]$Force) {
  if (-not $script:WavBytes) { return }
  if (-not $Force -and -not $script:Set.Sound) { return }
  try {
    if ($script:WavVol -ne $script:Set.Volume -or -not $script:WavScaled) {
      $g = [math]::Pow(([double]$script:Set.Volume / 100.0), 2)
      $b = [byte[]]$script:WavBytes.Clone()
      for ($i = 44; $i -lt $b.Length - 1; $i += 2) {
        $v = [int]([BitConverter]::ToInt16($b, $i) * $g)
        $b[$i] = [byte]($v -band 0xFF); $b[$i+1] = [byte](($v -shr 8) -band 0xFF)
      }
      $script:WavScaled = $b; $script:WavVol = $script:Set.Volume
    }
    $b = $script:WavScaled
    if ($script:Player) { $script:Player.Stop() }
    $script:Player = New-Object System.Media.SoundPlayer((New-Object IO.MemoryStream(,$b)))
    $script:Player.Play()
  } catch { Log-Error 'sound' $_ }
}

$script:Busy = $false; $script:Paused = $false; $script:Proc = $null; $script:CurJob = $null; $script:ui = @{}

function Style-Window($f) {
  try { $v = 2; [void][Pult.Native]::DwmSetWindowAttribute($f.Handle, 33, [ref]$v, 4) } catch {}
  try { $v = 0x00403A3A; [void][Pult.Native]::DwmSetWindowAttribute($f.Handle, 34, [ref]$v, 4) } catch {}
  try { $v = 1; [void][Pult.Native]::DwmSetWindowAttribute($f.Handle, 20, [ref]$v, 4) } catch {}  # тёмная рамка
}
function Round-Ctl($c, [int]$r) {
  $p = New-Object System.Drawing.Drawing2D.GraphicsPath
  $w = $c.Width; $h = $c.Height; $d = 2*$r
  $p.AddArc(0, 0, $d, $d, 180, 90); $p.AddArc($w-$d-1, 0, $d, $d, 270, 90)
  $p.AddArc($w-$d-1, $h-$d-1, $d, $d, 0, 90); $p.AddArc(0, $h-$d-1, $d, $d, 90, 90); $p.CloseFigure()
  $c.Region = New-Object System.Drawing.Region($p)
}
function New-Label($text, $font, $color, $x, $y, $w) {
  $l = New-Object System.Windows.Forms.Label
  $l.Text = $text; $l.Font = $font; $l.ForeColor = $color; $l.BackColor = [System.Drawing.Color]::Transparent
  $l.AutoSize = $true; $l.MaximumSize = New-Object System.Drawing.Size($w, 0)
  $l.Location = New-Object System.Drawing.Point($x, $y); $l.UseMnemonic = $false
  return $l
}
function New-Btn($text, $bg, $hover, $x, $y, $w, $h) {
  $b = New-Object System.Windows.Forms.Button
  $b.Text = $text; $b.FlatStyle = 'Flat'; $b.FlatAppearance.BorderSize = 0
  $b.BackColor = $bg; $b.FlatAppearance.MouseOverBackColor = $hover; $b.FlatAppearance.MouseDownBackColor = $hover
  $b.ForeColor = [System.Drawing.Color]::White; $b.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
  $b.Size = New-Object System.Drawing.Size($w, $h); $b.Location = New-Object System.Drawing.Point($x, $y)
  $b.Cursor = [System.Windows.Forms.Cursors]::Hand; $b.TabStop = $false
  return $b
}
function Add-Drag($f) {
  $f.add_MouseDown({ param($s,$e) if ($e.Button -eq 'Left') { $script:drag = $e.Location } })
  $f.add_MouseMove({ param($s,$e) if ($script:drag -and $e.Button -eq 'Left') { $s.Left += $e.X - $script:drag.X; $s.Top += $e.Y - $script:drag.Y } })
  $f.add_MouseUp({ $script:drag = $null })
}

# ================= Окно подтверждения =================
function Toggle-Cmd {
  $u = $script:ui
  $u.Open = -not $u.Open
  $delta = $u.BoxH + (S 12)
  if ($u.Open) {
    $u.Card.Visible = $true; $u.Foot.Top = $u.YCard + $delta
    $u.Form.Top -= $delta; $u.Form.Height += $delta; $u.Tog.Text = 'Скрыть команду  ⌃'
  } else {
    $u.Card.Visible = $false; $u.Foot.Top = $u.YCard
    $u.Form.Height -= $delta; $u.Form.Top += $delta; $u.Tog.Text = $u.TogText
  }
}

function Ask-User($job) {
  $W = S 400; $P = S 16; $IW = $W - 2*$P
  $f = New-Object Pult.QuietForm
  $f.FormBorderStyle = 'None'; $f.ShowInTaskbar = $false; $f.StartPosition = 'Manual'
  $f.BackColor = $script:cBg; $f.Opacity = 0; $f.KeyPreview = $true; $f.Icon = $script:AppIcon
  $fTitle = New-Object System.Drawing.Font('Segoe UI Semibold', 10)
  $fBody  = New-Object System.Drawing.Font('Segoe UI', 9.5)
  $fSmall = New-Object System.Drawing.Font('Segoe UI', 8.5)
  $fCode  = New-Object System.Drawing.Font('Consolas', 9.5)
  $y = $P
  if ($script:Logo) {
    $pb = New-Object System.Windows.Forms.PictureBox
    $pb.Image = $script:Logo; $pb.SizeMode = 'Zoom'; $pb.Size = New-Object System.Drawing.Size((S 18),(S 18))
    $pb.Location = New-Object System.Drawing.Point($P, $y); $f.Controls.Add($pb)
  }
  $f.Controls.Add((New-Label ('Claude  ·  ' + $job.Thread) $fSmall $script:cMuted ($P + (S 26)) ($y + (S 1)) ($IW - (S 70))))
  $f.Controls.Add((New-Label (Get-Date -Format 'HH:mm') $fSmall $script:cMuted ($W - $P - (S 34)) ($y + (S 1)) (S 34)))
  $y += S 28
  $t1 = New-Label $job.Desc $fTitle $script:cText $P $y $IW
  $f.Controls.Add($t1); $y += $t1.PreferredHeight + (S 4)
  if ($job.Details) {
    $t2 = New-Label $job.Details $fBody $script:cMuted $P $y $IW
    $f.Controls.Add($t2); $y += $t2.PreferredHeight + (S 2)
  }
  $y += S 8
  $lines = ($job.Cmd -split "`r?`n").Count
  $togText = 'Показать команду  ›   ' + $lines + ' стр.'
  $tog = New-Label $togText $fSmall $script:cAccentH $P $y $IW
  $tog.Cursor = [System.Windows.Forms.Cursors]::Hand
  $f.Controls.Add($tog); $y += $tog.PreferredHeight + (S 10)
  $yCard = $y
  $lh = [int]$fCode.GetHeight() + 1
  $boxH = [math]::Min([math]::Max($lines, 1), 10) * $lh + (S 18)
  $card = New-Object System.Windows.Forms.Panel
  $card.BackColor = $script:cCard; $card.Location = New-Object System.Drawing.Point($P, $yCard); $card.Size = New-Object System.Drawing.Size($IW, $boxH)
  $card.Padding = New-Object System.Windows.Forms.Padding((S 9)); $card.Visible = $false
  $tb = New-Object System.Windows.Forms.TextBox
  $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.BorderStyle = 'None'; $tb.WordWrap = $true
  $tb.ScrollBars = if ($lines -gt 10) { 'Vertical' } else { 'None' }
  $tb.BackColor = $script:cCard; $tb.ForeColor = $script:cCode; $tb.Font = $fCode; $tb.Dock = 'Fill'; $tb.TabStop = $false
  $tb.Text = $job.Cmd -replace "`r?`n", "`r`n"
  $card.Controls.Add($tb); $f.Controls.Add($card)
  $foot = New-Object System.Windows.Forms.Panel
  $foot.BackColor = $script:cBg; $foot.Location = New-Object System.Drawing.Point(0, $yCard)
  $bh = S 32; $bw = S 112
  $foot.Size = New-Object System.Drawing.Size($W, ($bh + $P))
  $yes = New-Btn 'Выполнить' $script:cAccent $script:cAccentH ($W - $P - $bw) 0 $bw $bh
  $no  = New-Btn 'Отклонить' $script:cGray $script:cGrayH ($W - $P - 2*$bw - (S 8)) 0 $bw $bh
  $yes.add_Click({ Resolve-Ask $true }); $no.add_Click({ Resolve-Ask $false })
  $foot.Controls.Add($no); $foot.Controls.Add($yes)
  $f.Controls.Add($foot)
  $baseH = $yCard + $bh + $P
  $f.ClientSize = New-Object System.Drawing.Size($W, $baseH)
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $f.Location = New-Object System.Drawing.Point(($wa.Right - $W - (S 16)), ($wa.Bottom - $baseH - (S 16)))

  $script:ui = @{ Form = $f; Card = $card; Foot = $foot; Tog = $tog; TogText = $togText; BoxH = $boxH; YCard = $yCard; Open = $false; Yes = $yes; No = $no }
  $tog.add_Click({ try { Toggle-Cmd } catch { Log-Error 'toggle' $_ } })
  Add-Drag $f
  $script:fade = New-Object System.Windows.Forms.Timer; $script:fade.Interval = 15
  $script:fade.add_Tick({ try { $fm = $script:ui.Form; if ($fm -and $fm.Opacity -lt 0.98) { $fm.Opacity += 0.14 } else { if ($fm) { $fm.Opacity = 0.98 }; $this.Stop() } } catch { try { $this.Stop() } catch {} } })
  $f.add_Shown({
    try {
      $u = $script:ui; Style-Window $u.Form; Round-Ctl $u.Yes (S 8); Round-Ctl $u.No (S 8)
      if ($script:Set.Expand) { Toggle-Cmd }
      $script:fade.Start()
    } catch { Log-Error 'shown' $_; $script:ui.Form.Opacity = 1 }
  })
  $f.Show()
}

# ================= Тихое уведомление (не перехватывает фокус) =================
function Close-Toast { try { if ($script:toastTimer) { $script:toastTimer.Stop() }; if ($script:toast -and -not $script:toast.IsDisposed) { $script:toast.Close(); $script:toast.Dispose() } } catch {}; $script:toast = $null }
function Show-Toast($title, $text, $color, [int]$ms, [scriptblock]$onClick) {
  try {
    Close-Toast
    $W = S 320; $P = S 14
    $t = New-Object Pult.QuietForm
    $t.FormBorderStyle = 'None'; $t.ShowInTaskbar = $false; $t.StartPosition = 'Manual'; $t.BackColor = $script:cBg
    $dot = New-Object System.Windows.Forms.Panel
    $dot.Size = New-Object System.Drawing.Size((S 4), (S 38)); $dot.Location = New-Object System.Drawing.Point($P, $P); $dot.BackColor = $color
    $t.Controls.Add($dot)
    $l1 = New-Label $title (New-Object System.Drawing.Font('Segoe UI Semibold', 10)) $script:cText ($P + (S 14)) $P ($W - 3*$P)
    $l2 = New-Label $text (New-Object System.Drawing.Font('Segoe UI', 9)) $script:cMuted ($P + (S 14)) ($P + (S 21)) ($W - 3*$P)
    $t.Controls.Add($l1); $t.Controls.Add($l2)
    $h = [math]::Max((S 40), (S 21) + $l2.PreferredHeight)
    $t.ClientSize = New-Object System.Drawing.Size($W, ($P*2 + $h))
    $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $t.Location = New-Object System.Drawing.Point(($wa.Right - $W - (S 16)), ($wa.Bottom - $t.Height - (S 16)))
    $script:toast = $t; $script:toastClick = $onClick
    $click = { $cb = $script:toastClick; Close-Toast; if ($cb) { try { & $cb } catch { Log-Error 'toast-click' $_ } } }
    foreach ($c in @($t, $l1, $l2, $dot)) { $c.Cursor = [System.Windows.Forms.Cursors]::Hand; $c.add_Click($click) }
    $t.add_Shown({ try { if ($script:toast) { Style-Window $script:toast } } catch {} })
    $script:toastTimer = New-Object System.Windows.Forms.Timer; $script:toastTimer.Interval = $ms
    $script:toastTimer.add_Tick({ try { $this.Stop() } catch {}; Close-Toast })
    $t.Show(); $script:toastTimer.Start()
  } catch { Log-Error 'toast' $_ }
}

# ================= Окно настроек =================
function Show-Settings {
  if ($script:setForm -and -not $script:setForm.IsDisposed) { $script:setForm.Activate(); return }
  $W = S 360; $P = S 18; $IW = $W - 2*$P
  $f = New-Object System.Windows.Forms.Form
  $f.FormBorderStyle = 'None'; $f.TopMost = $true; $f.StartPosition = 'Manual'; $f.ShowInTaskbar = $true
  $f.Text = 'Пульт Claude — настройки'; $f.BackColor = $script:cBg; $f.Icon = $script:AppIcon; $f.KeyPreview = $true
  $fT = New-Object System.Drawing.Font('Segoe UI Semibold', 11); $fB = New-Object System.Drawing.Font('Segoe UI', 9.5); $fS = New-Object System.Drawing.Font('Segoe UI', 8.5)
  $y = $P
  if ($script:Logo) {
    $pb = New-Object System.Windows.Forms.PictureBox; $pb.Image = $script:Logo; $pb.SizeMode = 'Zoom'
    $pb.Size = New-Object System.Drawing.Size((S 22),(S 22)); $pb.Location = New-Object System.Drawing.Point($P, $y); $f.Controls.Add($pb)
  }
  $f.Controls.Add((New-Label 'Пульт Claude' $fT $script:cText ($P + (S 30)) ($y) (S 200)))
  $x = New-Label '✕' $fB $script:cMuted ($W - $P - (S 12)) ($y + (S 2)) (S 20); $x.Cursor = [System.Windows.Forms.Cursors]::Hand
  $x.add_Click({ $script:setForm.Close() }); $f.Controls.Add($x)
  $y += S 40

  # Громкость
  $f.Controls.Add((New-Label 'Громкость звука' $fB $script:cText $P $y (S 200)))
  $vl = New-Label ([string]$script:Set.Volume + '%') $fB $script:cMuted ($W - $P - (S 44)) $y (S 44); $f.Controls.Add($vl)
  $y += S 26
  $tr = New-Object System.Windows.Forms.TrackBar
  $tr.Minimum = 0; $tr.Maximum = 100; $tr.TickFrequency = 10; $tr.SmallChange = 5; $tr.LargeChange = 10
  $tr.Value = [int]$script:Set.Volume; $tr.Location = New-Object System.Drawing.Point(($P - (S 6)), $y); $tr.Size = New-Object System.Drawing.Size(($IW + (S 12)), (S 30))
  $tr.BackColor = $script:cBg; $tr.TickStyle = 'None'
  $script:volLbl = $vl
  $tr.add_ValueChanged({ param($s,$e) $script:Set.Volume = $s.Value; $script:volLbl.Text = [string]$s.Value + '%' })
  $tr.add_MouseUp({ Save-Settings; Play-Ding -Force })
  $f.Controls.Add($tr); $y += S 40

  function Add-Check($text, $key) {
    $cb = New-Object System.Windows.Forms.CheckBox
    $cb.Text = $text; $cb.Font = $fB; $cb.ForeColor = $script:cText; $cb.BackColor = $script:cBg; $cb.FlatStyle = 'Flat'
    $cb.Checked = [bool]$script:Set[$key]; $cb.Tag = $key; $cb.AutoSize = $true
    $cb.Location = New-Object System.Drawing.Point($P, $script:sy); $cb.Cursor = [System.Windows.Forms.Cursors]::Hand
    $cb.add_CheckedChanged({ param($s,$e) $script:Set[$s.Tag] = $s.Checked; Save-Settings })
    $script:setForm.Controls.Add($cb); $script:sy += S 30
  }
  $script:setForm = $f; $script:sy = $y
  Add-Check 'Тихий звук при новой команде' 'Sound'
  Add-Check 'Уведомление «Готово» после выполнения' 'ResultToast'
  Add-Check 'Сразу показывать текст команды' 'Expand'
  $cbA = New-Object System.Windows.Forms.CheckBox
  $cbA.Text = 'Запускать вместе с Windows'; $cbA.Font = $fB; $cbA.ForeColor = $script:cText; $cbA.BackColor = $script:cBg; $cbA.FlatStyle = 'Flat'
  $cbA.AutoSize = $true; $cbA.Checked = (Test-Path $script:Startup); $cbA.Location = New-Object System.Drawing.Point($P, $script:sy); $cbA.Cursor = [System.Windows.Forms.Cursors]::Hand
  $cbA.add_CheckedChanged({ param($s,$e)
    try {
      if ($s.Checked) { Copy-Item (Join-Path $script:AppDir 'start.vbs') $script:Startup -Force } else { Remove-Item $script:Startup -Force -ErrorAction SilentlyContinue }
    } catch { Log-Error 'autostart' $_ }
  })
  $f.Controls.Add($cbA); $y = $script:sy + (S 40)

  $bt = New-Btn 'Проверить звук' $script:cGray $script:cGrayH $P $y (S 140) (S 32)
  $bt.add_Click({ Play-Ding -Force }); $f.Controls.Add($bt)
  $bo = New-Btn 'Папка пульта' $script:cGray $script:cGrayH ($W - $P - (S 140)) $y (S 140) (S 32)
  $bo.add_Click({ Start-Process explorer.exe $script:Root }); $f.Controls.Add($bo)
  $y += (S 32) + $P
  $f.ClientSize = New-Object System.Drawing.Size($W, $y)
  $wa = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
  $f.Location = New-Object System.Drawing.Point(($wa.Right - $W - (S 16)), ($wa.Bottom - $y - (S 16)))
  $f.add_KeyDown({ param($s,$e) if ($e.KeyCode -eq 'Escape') { $s.Close() } })
  $f.add_Shown({ Style-Window $script:setForm; foreach ($c in $script:setForm.Controls) { if ($c -is [System.Windows.Forms.Button]) { Round-Ctl $c (S 8) } } })
  Add-Drag $f
  $f.Show()
}

# ================= Трей =================
$script:tray = New-Object System.Windows.Forms.NotifyIcon
$script:tray.Icon = $script:AppIcon; $script:tray.Text = 'Пульт Claude — ждёт команд'; $script:tray.Visible = $true
$menu = New-Object System.Windows.Forms.ContextMenuStrip
$menu.Items.Add('Настройки…').add_Click({ try { Show-Settings } catch { Log-Error 'settings-ui' $_ } })
$menu.Items.Add('Открыть папку пульта').add_Click({ Start-Process explorer.exe $script:Root })
$script:miPause = $menu.Items.Add('Пауза')
$script:miPause.add_Click({
  $script:Paused = -not $script:Paused
  if ($script:Paused) { $script:miPause.Text = 'Продолжить'; $script:tray.Text = 'Пульт Claude — на паузе' }
  else { $script:miPause.Text = 'Пауза'; $script:tray.Text = 'Пульт Claude — ждёт команд' }
})
[void]$menu.Items.Add('-')
$menu.Items.Add('Выход').add_Click({ $script:tray.Visible = $false; [System.Windows.Forms.Application]::Exit() })
$script:tray.ContextMenuStrip = $menu
$script:tray.add_MouseClick({ param($s,$e) if ($e.Button -eq 'Left') { try { Show-Settings } catch { Log-Error 'tray-click' $_ } } })

# ================= Очередь команд =================
function Write-Answer($name, $text) { [IO.File]::WriteAllText((Join-Path $script:Outbox ($name + '.log')), $text, $script:Utf8NoBom) }

function Parse-Job($path) {
  $lines = [IO.File]::ReadAllLines($path, [Text.Encoding]::UTF8)
  $job = @{ Thread = '(не указан)'; Desc = '(без описания)'; Details = ''; Cmd = '' }
  $i = 0
  while ($i -lt $lines.Count) {
    $ln = $lines[$i]
    if ($ln -match '^\s*(ТРЕД|THREAD)\s*:\s*(.*)$') { $job.Thread = $Matches[2]; $i++; continue }
    if ($ln -match '^\s*(ОПИСАНИЕ|DESC)\s*:\s*(.*)$') { $job.Desc = $Matches[2]; $i++; continue }
    if ($ln -match '^\s*(ПОДРОБНО|DETAILS)\s*:\s*(.*)$') { $job.Details = $Matches[2]; $i++; continue }
    if ($ln.Trim() -eq '') { $i++; break }
    break
  }
  $job.Cmd = (($lines | Select-Object -Skip $i) -join "`r`n").Trim()
  return $job
}

function Get-Pending {
  Get-ChildItem -LiteralPath $script:Inbox -Filter '*.txt' -File -ErrorAction SilentlyContinue |
    Where-Object { ((Get-Date) - $_.LastWriteTime).TotalSeconds -ge 2 } | Sort-Object LastWriteTime
}
function Update-Tray {
  if ($script:Proc) { $script:tray.Icon = $script:AppIcon; $script:tray.Text = 'Пульт Claude — выполняю...'; return }
  if ($script:PendingJob) { $script:tray.Icon = $script:AlertIcon; $script:tray.Text = 'Пульт Claude — ждёт твоего ответа'; return }
  $script:tray.Icon = $script:AppIcon
  $script:tray.Text = $(if ($script:Paused) { 'Пульт Claude — на паузе' } else { 'Пульт Claude — ждёт команд' })
}

# Новая команда: одно тихое окно сразу с кнопками (без кражи фокуса)
function Notify-Next {
  if ($script:Busy -or $script:Paused) { return }
  $file = Get-Pending | Select-Object -First 1
  if (-not $file) { return }
  $script:Busy = $true
  $name = [IO.Path]::GetFileNameWithoutExtension($file.Name)
  try {
    $job = Parse-Job $file.FullName
    Move-Item -LiteralPath $file.FullName -Destination (Join-Path $script:Done $file.Name) -Force
    if ($job.Cmd -eq '') { Write-Answer $name "ПУСТО`r`n"; $script:Busy = $false; return }
    $script:PendingJob = @{ Name = $name; Job = $job }
    Update-Tray; Play-Ding
    Ask-User $job
  } catch {
    Log-Error "ask:$name" $_
    Write-Answer $name ("ОШИБКА ПУЛЬТА при показе окна: " + $_ + "`r`n")
    $script:PendingJob = $null; $script:Busy = $false
  }
}

function Resolve-Ask([bool]$ok) {
  $pj = $script:PendingJob
  $script:PendingJob = $null
  try { $f = $script:ui.Form; if ($f -and -not $f.IsDisposed) { $f.Hide(); $f.Close() } } catch {}
  $script:ui = @{}
  if (-not $pj) { $script:Busy = $false; return }
  if (-not $ok) {
    Write-Answer $pj.Name ("ОТКЛОНЕНО пользователем " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`n")
    $script:Busy = $false; Update-Tray; return
  }
  $name = $pj.Name; $job = $pj.Job
  try {
    $bat = Join-Path $script:WorkDir ($name + '.bat'); $log = Join-Path $script:WorkDir ($name + '.out')
    [IO.File]::WriteAllText($bat, "@echo off`r`nchcp 65001 >nul`r`n" + $job.Cmd + "`r`n", $script:Utf8NoBom)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'cmd.exe'; $psi.Arguments = '/c ""' + $bat + '" > "' + $log + '" 2>&1"'
    $psi.WindowStyle = 'Hidden'; $psi.CreateNoWindow = $true; $psi.UseShellExecute = $false
    $script:Proc = [System.Diagnostics.Process]::Start($psi)
    $script:CurJob = @{ Name = $name; Log = $log; Bat = $bat; Start = Get-Date; Desc = $job.Desc }
    Update-Tray
  } catch {
    Log-Error "run:$name" $_
    Write-Answer $name ("ОШИБКА ПУЛЬТА при запуске: " + $_ + "`r`n")
    $script:Busy = $false
  }
}

function Check-Running {
  if (-not $script:Proc) { return }
  $j = $script:CurJob
  $timeout = ((Get-Date) - $j.Start).TotalMinutes -gt 30
  if (-not $script:Proc.HasExited -and -not $timeout) { return }
  if ($timeout -and -not $script:Proc.HasExited) { try { $script:Proc.Kill() } catch {}; $code = 'ТАЙМАУТ 30 мин' } else { $code = $script:Proc.ExitCode }
  Start-Sleep -Milliseconds 300
  $out = ''; if (Test-Path $j.Log) { $out = [IO.File]::ReadAllText($j.Log) }
  Write-Answer $j.Name ("ВЫПОЛНЕНО " + (Get-Date -Format 'yyyy-MM-dd HH:mm:ss') + "`r`nКОД: $code`r`n----`r`n" + $out)
  Remove-Item -LiteralPath $j.Bat, $j.Log -ErrorAction SilentlyContinue
  $script:Proc = $null; $script:CurJob = $null; $script:Busy = $false
  $script:tray.Text = 'Пульт Claude — ждёт команд'
  $ok = ($code -eq 0)
  if ($script:Set.ResultToast) { Show-Toast ($(if ($ok) { 'Готово' } else { "Завершено с кодом $code" })) $j.Desc ($(if ($ok) { C '#3CCB7F' } else { C '#FF5A5F' })) 3500 $null }
}

$script:timer = New-Object System.Windows.Forms.Timer
$script:timer.Interval = 2000
$script:timer.add_Tick({ try { Check-Running; Notify-Next; Update-Tray } catch { Log-Error 'tick' $_ } })
$script:timer.Start()
[System.Windows.Forms.Application]::Run()
$script:tray.Dispose()
try { $mutex.ReleaseMutex() } catch {}
