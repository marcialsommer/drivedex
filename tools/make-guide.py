import sys
from PIL import Image
from reportlab.lib.pagesizes import A4
from reportlab.lib.units import mm
from reportlab.lib import colors
from reportlab.lib.styles import ParagraphStyle
from reportlab.platypus import (BaseDocTemplate, PageTemplate, Frame, Paragraph, Spacer, Image as RLImage,
                                Table, TableStyle, PageBreak, KeepTogether, NextPageTemplate)
S=sys.argv[1]; OUT=sys.argv[2]; ICON=sys.argv[3]; GK=sys.argv[4]; G=S+'/g3'
ACC=colors.HexColor('#2f6fdf'); INK=colors.HexColor('#1d1d1f'); MUTE=colors.HexColor('#6e6e73'); LINE=colors.HexColor('#e3e3e0'); TINT=colors.HexColor('#eef3fd')
WARN=colors.HexColor('#d9822b')
W,H=A4; M=20*mm; CW=W-2*M
def st(**k):
    b=dict(fontName='Helvetica', fontSize=10.5, leading=15, textColor=INK); b.update(k); return ParagraphStyle('x', **b)
body=st(spaceAfter=6); small=st(fontSize=9.5, leading=13.5)
h1=st(fontName='Helvetica-Bold', fontSize=20, leading=25, spaceBefore=2, spaceAfter=10)
h2=st(fontName='Helvetica-Bold', fontSize=13, leading=17, spaceBefore=10, spaceAfter=5)
cap=st(fontSize=8.5, leading=11, textColor=MUTE, spaceBefore=3, spaceAfter=10)
num=st(fontName='Helvetica-Bold', fontSize=11, textColor=colors.white, alignment=1)
import os, re
from reportlab.pdfbase import pdfmetrics
from reportlab.pdfbase.ttfonts import TTFont
SYM=None
for f in ['/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf','/usr/share/fonts/dejavu/DejaVuSans.ttf']:
    if os.path.exists(f): pdfmetrics.registerFont(TTFont('Sym', f)); SYM='Sym'; break
SYMS={'&#8984;':'\u2318','⌘':'\u2318','⊘':'\u2298','&#x2715;':'\u2715','✕':'\u2715','&#9200;':'\u23f0','&#9888;':'\u26a0','⚠':'\u26a0','↺':'\u21ba','&#8987;':'\u231b'}
def fixsym(t):
    for k,v in SYMS.items():
        t=t.replace(k, f'<font name="{SYM}">{v}</font>' if SYM else {'\u2318':'Cmd','\u2298':'(excluded)','\u2715':'x','\u23f0':'','\u26a0':'!','\u21ba':'','\u231b':''}[v])
    return t
def P(t, s=body): return Paragraph(fixsym(t), s)
def img(name, width, box=None):
    p=f'{G}/{name}.png'; im=Image.open(p)
    if box: im=im.crop(box); p=f'{G}/{name}_c.png'; im.save(p)
    w,h=im.size; return RLImage(p, width=width, height=width*h/w)
def shot(name, caption, width=CW, box=None):
    i=img(name,width,box); t=Table([[i]], colWidths=[width]); t.setStyle(TableStyle([('BOX',(0,0),(-1,-1),0.6,LINE)]+[(k,(0,0),(-1,-1),0) for k in ('LEFTPADDING','RIGHTPADDING','TOPPADDING','BOTTOMPADDING')]))
    return KeepTogether([t, P(caption, cap)])
def side(name, width, text, box=None):
    i=img(name,width,box); fr=Table([[i]],colWidths=[width]); fr.setStyle(TableStyle([('BOX',(0,0),(-1,-1),0.6,LINE)]+[(k,(0,0),(-1,-1),0) for k in ('LEFTPADDING','RIGHTPADDING','TOPPADDING','BOTTOMPADDING')]))
    t=Table([[fr, P(text, small)]], colWidths=[width+7*mm, CW-width-7*mm]); t.setStyle(TableStyle([('VALIGN',(0,0),(-1,-1),'MIDDLE'),('LEFTPADDING',(0,0),(-1,-1),0)]))
    return KeepTogether([t, Spacer(1,8)])
def steps(items):
    rows=[]
    for i,t in enumerate(items,1):
        b=Table([[P(str(i),num)]], colWidths=[7*mm], rowHeights=[7*mm]); b.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,-1),ACC),('VALIGN',(0,0),(-1,-1),'MIDDLE'),('ROUNDEDCORNERS',[3.5*mm]*4),('TOPPADDING',(0,0),(-1,-1),0),('BOTTOMPADDING',(0,0),(-1,-1),1)]))
        rows.append([b, P(t)])
    t=Table(rows, colWidths=[11*mm, CW-11*mm]); t.setStyle(TableStyle([('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),0),('BOTTOMPADDING',(0,0),(-1,-1),5)]))
    return t
def note(t, bg=TINT, edge=ACC):
    x=Table([[P(t, small)]], colWidths=[CW]); x.setStyle(TableStyle([('BACKGROUND',(0,0),(-1,-1),bg),('LINEBEFORE',(0,0),(0,-1),3,edge),('LEFTPADDING',(0,0),(-1,-1),10),('RIGHTPADDING',(0,0),(-1,-1),10),('TOPPADDING',(0,0),(-1,-1),7),('BOTTOMPADDING',(0,0),(-1,-1),7)]))
    return KeepTogether([Spacer(1,3), x, Spacer(1,8)])
def bullets(items): return [P('&bull;&nbsp;&nbsp;'+t, st(leftIndent=12, firstLineIndent=-10, spaceAfter=3)) for t in items]
def table(rows, w1):
    t=Table([[P(a),P(b)] for a,b in rows], colWidths=[w1, CW-w1])
    t.setStyle(TableStyle([('LINEBELOW',(0,0),(-1,-1),0.5,LINE),('VALIGN',(0,0),(-1,-1),'TOP'),('LEFTPADDING',(0,0),(-1,-1),0),('TOPPADDING',(0,0),(-1,-1),4),('BOTTOMPADDING',(0,0),(-1,-1),4)])); return t
def footer(c,d):
    c.saveState(); c.setFont('Helvetica',8); c.setFillColor(MUTE); c.drawString(M,12*mm,'DriveDex user guide · version 2.1.11'); c.drawRightString(W-M,12*mm,str(d.page)); c.restoreState()
def cover(c,d):
    c.saveState(); c.setFillColor(TINT); c.rect(0,H-118*mm,W,118*mm,stroke=0,fill=1)
    c.drawImage(ICON, M-4*mm, H-78*mm, 42*mm, 42*mm, mask='auto')
    c.setFillColor(INK); c.setFont('Helvetica-Bold',34); c.drawString(M,H-96*mm,'DriveDex')
    c.setFont('Helvetica',14); c.setFillColor(MUTE); c.drawString(M,H-106*mm,'User guide  ·  Version 2.1.11'); c.restoreState()
doc=BaseDocTemplate(OUT, pagesize=A4, leftMargin=M, rightMargin=M, topMargin=M, bottomMargin=22*mm, title='DriveDex User Guide', author='DriveDex', subject='How to install and use DriveDex')
doc.addPageTemplates([PageTemplate('cover',[Frame(M,22*mm,CW,H-128*mm-22*mm)],onPage=cover), PageTemplate('page',[Frame(M,22*mm,CW,H-M-22*mm)],onPage=footer)])

s=[NextPageTemplate('page')]
s+=[P("Know what's on every drive, and whether it's backed up.", st(fontName='Helvetica-Bold', fontSize=15, leading=20, spaceAfter=10)),
    P('DriveDex keeps a catalog of every drive and NAS share you connect to your Mac. Once a drive is added, it is re-catalogued automatically whenever you plug it in. Browse and search all your drives (even ones in a drawer), see which drives back up which, get told when something isn\'t backed up, and share the whole catalog between your Macs.'),
    P('DriveDex only records file and folder <b>names, sizes and dates</b>. It never opens or reads the contents of your files.'),
    P('In this guide', h2)]
toc=['Install and update','Adding drives','The drive list','A drive\'s page and browsing','Searching','Setting up your backups','Is everything backed up?','Folders that don\'t need a backup','Backup reminders','Space and duplicates','Sharing between your Macs','Settings and shortcuts','Questions and troubleshooting']
half=(len(toc)+1)//2; cw=CW/2
rows=[[P(f'<font color="#2f6fdf"><b>{i+1}</b></font>'),P(toc[i]),P(f'<font color="#2f6fdf"><b>{i+1+half}</b></font>') if i+half<len(toc) else '',P(toc[i+half]) if i+half<len(toc) else ''] for i in range(half)]
t=Table(rows, colWidths=[8*mm, cw-12*mm, 8*mm, cw-4*mm]); t.setStyle(TableStyle([('LINEBELOW',(0,0),(-1,-1),0.5,LINE),('TOPPADDING',(0,0),(-1,-1),3),('BOTTOMPADDING',(0,0),(-1,-1),3),('LEFTPADDING',(0,0),(-1,-1),0)]))
s+=[t, PageBreak()]

# 1
s+=[P('1  Install and update', h1), P('Install once on every Mac (macOS 13 Ventura or newer, Apple Silicon or Intel).'),
    steps(['Download <b>DriveDex.dmg</b> from <font color="#2f6fdf">github.com/marcialsommer/drivedex/releases/latest</font>.',
           'Open it and drag <b>DriveDex</b> onto the <b>Applications</b> folder.',
           'Open DriveDex. macOS says it could not verify the app. Click <b>Done</b>, <i>not</i> Move to Trash.',
           'Open <b>System Settings &rarr; Privacy &amp; Security</b>, scroll to <b>Security</b> and click <b>Open Anyway</b> next to DriveDex.',
           'When DriveDex asks to access files on removable or network volumes, click <b>Allow</b>.'])]
gk=Image.open(GK); gw=46*mm
s+=[Spacer(1,4), Table([[RLImage(GK,width=gw,height=gw*gk.size[1]/gk.size[0]), P('<b>Why the warning?</b> Apple only skips it for apps signed with a paid developer certificate. You need <b>Open Anyway</b> only for the first install on each Mac. Updates installed from inside DriveDex don\'t need it.', small)]], colWidths=[gw+8*mm, CW-gw-8*mm], style=[('VALIGN',(0,0),(-1,-1),'MIDDLE'),('LEFTPADDING',(0,0),(-1,-1),0)]),
    P('Updates', h2),
    side('up', 58*mm, 'DriveDex checks for new versions a few times a day. When one is available you get a notification and this card at the top of the drive list. Click <b>Install &amp; Relaunch</b>: DriveDex downloads the update, replaces itself and restarts, keeping your catalog. You can also use <b>DriveDex menu &rarr; Check for Updates…</b> or <b>Settings &rarr; Updates</b>.<br/><br/>After an update macOS may ask once more for access to removable volumes; click <b>Allow</b>.'),
    P('This guide is always available in the app under <b>Help &rarr; DriveDex User Guide</b>, and on the download page as <b>DriveDex-Guide.pdf</b>.', small),
    P('Where DriveDex lives', h2),
    P('DriveDex runs in the <b>menu bar</b> (drive icon, top right) and starts when you log in. Closing the window doesn\'t stop it. The icon also shows your backup health (see section 7).'),
    PageBreak()]
# 2
s+=[P('2  Adding drives', h1),
    side('new', 58*mm, 'The first time DriveDex sees a drive, it <b>asks before cataloguing it</b>: a notification and a card at the top of the drive list.<br/><br/><b>Catalog it</b> adds the drive. <b>Ignore</b> means never ask again (for example camera cards). App installers (.dmg) are skipped automatically.'),
    P('After that, a known drive is updated automatically whenever you connect it (if its last scan is over an hour old). NAS shares that stay connected are rescanned every 12 hours.'),
    P('Drives are scanned <b>one at a time</b>, which is gentler on disks and usually faster overall than scanning several at once. A drive waiting its turn shows <b>Waiting to scan</b>, and <b>Rescan now</b> tells you whether the scan started or was queued.'),
    P('While anything is happening, a slim blue <b>activity bar</b> appears under the search field: which drive is being scanned, how many files so far, an estimate of how far along it is (based on the last scan), what\'s next, and which backups are being checked. It disappears when DriveDex is idle. The menu-bar menu shows the same.'),
    P('<b>Stopping a scan:</b> click <b>Stop</b> in the activity bar (or <b>Stop scan</b> on the drive\'s page), <b>&#x2715;</b> next to a waiting drive, or <b>Stop all</b>. The drive keeps its previous catalog, the scan history notes it was stopped, and DriveDex won\'t restart it by itself for 12 hours. Plugging it in again or pressing Rescan starts it as usual.'),
    P('Setup guide', h2),
    P('On a fresh install, a short guide walks you through it: sharing between Macs, adding drives, and marking main and backup drives. Open it any time from <b>Settings &rarr; Run the setup guide again</b>.'),
    shot('setup','The setup guide.', box=(0,0,1720,1050)),
    note('<b>Tip:</b> unplugging a drive mid-scan loses nothing. The previous catalog stays until the next complete scan.'),
    PageBreak()]
# 3
s+=[P('3  The drive list', h1),
    P('The left column shows <b>families</b>: each main drive in its own box with its backups indented below. Other drives are listed under <b>Other drives</b>.'),
    side('fam', 60*mm, '&bull; <font color="#2e9d58"><b>Green dot</b></font>: connected to this Mac now.<br/>&bull; <b>HDD / SSD / NAS</b> tag and <b>capacity</b>: the kind and size of drive.<br/>&bull; <b>Location</b>: where the drive lives (from its notes).<br/>&bull; <b>Checkmarks</b> (top right): one per backup; green complete, amber 90%+, red less.<br/>&bull; Each backup shows its own fullness bar, how complete it is and how old its catalog is. Folder backups show their folder.<br/>&bull; A backup split over several drives appears as <b>Backup set &middot; N drives</b>, with the combined percentage on that heading and the drives indented below.<br/>&bull; The small <b>&#9662;</b> arrow hides or shows a family\'s backups.'),
    side('compact', 46*mm, '<b>Wider list:</b> drag the border between the drive list and the main area to make the list wider (double-click it to reset). Long names wrap instead of being cut off.<br/><br/><b>Compact list:</b> the <b>&#9776;</b> button next to "Drives" shows one line per drive, which is handy with many drives.<br/><br/><b>Reorder:</b> drag a family box, or a drive under Other drives, up or down. A blue line shows where it lands. The order syncs to your other Macs.', box=(0,0,546,900)),
    side('dmenu', 42*mm, '<b>Right-click any drive</b> to open it, rescan it, show it in Finder, set its type and role, or <b>Forget drive</b>. Forgetting removes the drive and its catalog from DriveDex (and your other Macs if you share). Nothing on the drive is touched.'),
    PageBreak()]
# 4
s+=[P('4  A drive\'s page and browsing', h1),
    shot('dhead','The top of a drive\'s page: name, type, status, backup status, location, and the three tabs.'),
    table([('<b>Files</b>','Browse the drive\'s folders (opens first).'),('<b>Backups</b>','Main files / backup role, backup status, history and reminders (sections 6–9). On a backup drive this tab is called <b>Backup status</b>: what it backs up, how complete it is, and a link to the files it\'s missing.'),('<b>Info</b>','Size, last connected (and on which Mac), <b>scan history</b> (every scan with date, Mac, files, size and duration, including failed ones), type, location notes, Forget drive. Biggest folders and possible duplicates are in collapsed sections; click to open.')], 26*mm),
    Spacer(1,6), P('Column view', h2),
    shot('cols','Column view. Dots show each file\'s backup status; ⊘ marks an excluded folder.', box=(0,0,1640,350)),
    table([('<b>&darr; &uarr;</b>','Move up and down'),('<b>&rarr;</b> or <b>Return</b>','Open the selected folder'),('<b>&larr;</b>','Back to the parent folder'),('<b>Type a name</b>','Jump to the first item starting with those letters')], 38*mm),
    Spacer(1,6),
    P('Select a file to see its size, date, backup status and a <b>Show in Finder</b> button. <b>List</b> view (above the files) gives a sortable table with a Backups column. Click a drive\'s location or name to rename it, and edit its location under <b>Info</b>.'),
    PageBreak()]
# 5
s+=[P('5  Searching', h1),
    P('Type in the search box to search file and folder names on <b>all</b> drives, connected or not.'),
    shot('search','Identical items on several drives appear as one row ("on 3 drives"); click it to see each copy.', box=(0,0,2300,1000)),
    P('&bull;&nbsp;&nbsp;<b>Kind:</b> Everything, Folders, Files, Videos, Photos, Audio, Documents, Projects &amp; libraries, Archives.', st(leftIndent=12, firstLineIndent=-10, spaceAfter=3))]
s+=bullets(['<b>Where:</b> all drives, one drive, or <b>In "folder"</b>: start typing while you\'re in a folder to search only there.',
            'Drives that aren\'t connected show their location so you know where to find them.',
            'Click a result to open its folder. Click <b>&#x2715;</b> or press <b>Esc</b> to clear the search and return to where you were.'])
s+=[PageBreak()]
# 6
s+=[P('6  Setting up your backups', h1),
    P('Whole drives', h2),
    steps(['Open a drive with your originals &rarr; <b>Backups</b> tab &rarr; set <b>This drive holds</b> to <b>Main files</b>. Drives that are neither stay <b>Not marked</b>. If a change would remove backup links, DriveDex asks first.',
           'Open a backup drive &rarr; <b>Backup status</b> tab &rarr; set <b>This drive holds</b> to <b>Backup</b>.',
           'Under <b>Backs up</b>, tick every main drive it contains. Names like "Samsung T7 Backup" are suggested automatically.']),
    P('A folder as a backup location', h2),
    P('If a drive is backed up into a folder on another drive (for example "Denali" into "Backups/Denali" on the NAS), open that folder and choose the drive under <b>This folder is a backup of</b>, or right-click it &rarr; <b>Use as backup location…</b>.'),
    shot('fbar','Inside a NAS folder: "This folder is a backup of: Denali".'),
    P('A backup split across several drives', h2),
    P('If a drive\'s backup is spread over two drives (for example "Archive" on "Archive Backup A" and "B"), assign both, then on the main drive\'s Backups tab choose <b>Combine with…</b>. They are then checked together as one <b>SET</b>. <b>Split</b> undoes it.'),
    shot('set','A backup set: two drives that together hold one backup.'),
    PageBreak()]
# 7
s+=[P('7  Is everything backed up?', h1),
    P('Home: Needs attention', h2),
    P('Click <b>Overview</b> at the top of the drive list (its badge counts what needs attention), or the <b>DriveDex</b> title, to come back here from anywhere.'),
    shot('home','The home screen lists everything that needs you, with a button to fix each. When all is well it says "Everything is backed up".'),
    P('Menu bar', h2),
    P('The DriveDex icon in the menu bar turns <font color="#d9822b"><b>orange</b></font> when something needs attention and <font color="#d33f3f"><b>red</b></font> when files have no backup at all. Its menu lists every main drive with its status; click one to open it.'),
    KeepTogether([P('A drive\'s Backups tab', h2),
    shot('backups','Overall bar, one row per backup (or set), reminder, excluded folders and history.', width=CW*0.8)]),
    P('<b>Percentages are by data</b> (how many GB/TB have a copy); the number of files is shown next to them. A backup only shows 100% when nothing at all is missing. The bar shows all data: <font color="#2e9d58"><b>green</b></font> on 2+ backups, <font color="#d9822b"><b>amber</b></font> on exactly 1, <font color="#d33f3f"><b>red</b></font> on none. Each backup row shows how complete it is, when it was last fully <b>in sync</b>, and how old its catalog is. Click the amber <b>&#9888; missing</b> link to see exactly which files that backup lacks.'),
    shot('setmiss','Files missing from one backup set. Click a file to jump to its folder.', width=CW*0.7),
    P('From a backup drive', h2),
    P('Open a backup drive (or a NAS that holds a folder backup): its header says e.g. <b>&#9888; 233 files missing &rsaquo;</b>. Click it for the list of files that backup doesn\'t have. The <b>Backup status</b> tab shows each drive it backs up, how complete it is and when it was last in sync.'),
    note('<b>How matching works:</b> a file counts as backed up when the backup has a file with the same name and size, in any folder. Invisible name differences between a Mac and a NAS (umlauts, special characters) are ignored. Turn on <b>Strict backup check</b> in Settings to also require the same modification date. Each backup is only as current as its last catalog.', colors.HexColor('#fff7e8'), WARN),
    PageBreak()]
# 8 9 10
s+=[P('8  Folders that don\'t need a backup', h1),
    side('fmenu', 44*mm, '<b>Right-click a folder &rarr; Exclude from backup check.</b> It stays visible, greyed out with <b>⊘</b>, and its files (including subfolders) no longer count as missing. Right-click again &rarr; <b>Include in backup check</b> to undo. Excluded folders are also listed on the Backups tab.'),
    P('9  Backup reminders', h1),
    P('If you rotate backup drives (for example two NAS backup drives swapped between home and office), set <b>Remind me when a backup hasn\'t been updated for</b> 3 days, 1 week, 2 weeks or 1 month on the main drive\'s Backups tab. You get a notification (at most once a day), it appears under <b>Needs attention</b>, and the backup is marked <font color="#d9822b"><b>Due</b></font>. Connecting the backup resets it.'),
    P('10  Space and duplicates', h1),
    shot('info','Info tab: biggest folders, and large files that also exist on other (non-backup) drives.', width=CW*0.85),
    PageBreak()]
# 11
s+=[P('11  Sharing between your Macs', h1),
    steps(['On the Mac that knows the most drives: <b>Settings</b> (&#8984;,) &rarr; <b>Share with iCloud Drive</b>, or <b>Use another folder…</b> (Google Drive, Dropbox…).',
           'On every other Mac choose <b>the same</b> option or folder.',
           'After a few minutes all drives appear on every Mac.']),
    shot('sync','Sharing is on. "Sync now" checks for changes immediately.'),
    P('Each Mac keeps a <b>working copy</b> of the catalog (fast, works offline) and exchanges updates through the <b>shared copy</b> in your sync folder (a subfolder called <b>DriveDex</b>).'),
    table([('<b>Shared</b>','Drives and catalogs, names, notes and locations, types, roles, backup assignments (drives, folders, sets), excluded folders, reminders, history, drive order, ignored drives, strict check, and which Mac last saw each drive.'),
           ('<b>Per Mac</b>','Start at login, notifications, rescan timing, compact view, and the green "connected" dot (always about this Mac).')], 22*mm),
    Spacer(1,6)]
s+=bullets(['Use a folder your Mac keeps in sync in the background. Don\'t edit or move files inside the DriveDex folder.',
            'A folder on an external drive or NAS works only while it\'s connected.',
            '<b>Stop sharing</b> keeps everything already on this Mac.'])
s+=[PageBreak()]
# 12
s+=[P('12  Settings and shortcuts', h1),
    table([('<b>Open DriveDex at login</b>','Keep on: DriveDex only catalogs drives while running.'),
           ('<b>Notifications</b>','When scans finish or fail, and for reminders and updates.'),
           ('<b>Ask before cataloguing new drives</b>','On: new drives wait for <b>Catalog it</b>.'),
           ('<b>Rescan when plugged in / network shares</b>','How old a catalog may get before a rescan (1 hour / 12 hours).'),
           ('<b>Strict backup check</b>','Also compare modification dates (section 7).'),
           ('<b>Never scan these drives</b>','Names to skip. Drives you Ignore are added here.'),
           ('<b>Share between Macs</b>','Section 11.'),('<b>Help / Updates</b>','Open this guide, run the setup guide again, check for and install updates.')], 58*mm),
    P('Keyboard shortcuts', h2),
    table([('<b>&#8984; ,</b>','Settings (press again, or click Settings again, to go back)'),('<b>&#8984; F</b> or <b>/</b>','Search'),('<b>Esc</b>','Clear the search, close a menu'),('<b>&#8984; R</b>','Rescan connected drives'),('<b>&#8984; W</b> / <b>&#8984; Q</b>','Close the window (keeps running) / quit'),('<b>&#8984; ?</b>','Open this user guide'),('<b>Arrow keys</b>','Move around in the Column view')], 38*mm),
    PageBreak()]
# 13
s+=[P('13  Questions and troubleshooting', h1)]
faq=[('A drive shows "macOS blocked access".','Info tab &rarr; <b>Open Privacy Settings</b> and allow DriveDex (or add it under Full Disk Access). Then <b>Rescan now</b>.'),
     ('I plugged in a drive and nothing happened.','Look for the <b>New drive</b> card. Otherwise check DriveDex is running (menu-bar icon); a drive scanned within the last hour is skipped (use <b>Rescan now</b>).'),
     ('A backup I just finished shows 99.x%.','Rescan the backup (its catalog may predate the end of the backup), then click the amber <b>&#9888; missing</b> link to see which files. Often they are files changed after the backup, like an open Lightroom catalog.'),
     ('My backup is split over two drives and each shows about 50%.','Combine them into a set (section 6).'),
     ('The drives from my other Mac don\'t appear.','Both Macs must use the same sync folder. Click <b>Sync now</b>; the folder should contain files ending in <i>.entries.db</i> and <i>.meta.json</i>.'),
     ('An update failed to install.','The old version stays. Download the latest DriveDex.dmg and install it manually (section 1).'),
     ('Does DriveDex read or upload my files?','No. Only names, sizes and dates, kept on your Macs and in your own sync folder.'),
     ('How do I remove DriveDex?','Quit it, turn off "Open DriveDex at login", drag it to the Bin. To erase the catalog, delete <i>~/Library/Application Support/DriveDex</i> and the DriveDex folder in your sync folder.')]
for q,a in faq: s.append(KeepTogether([P(q, st(fontName='Helvetica-Bold', spaceBefore=6, spaceAfter=2)), P(a)]))
doc.build(s); print('ok')
