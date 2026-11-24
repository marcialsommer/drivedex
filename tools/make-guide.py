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
    c.saveState(); c.setFont('Helvetica',8); c.setFillColor(MUTE); c.drawString(M,12*mm,'DriveDex user guide · version 2.15.1'); c.drawRightString(W-M,12*mm,str(d.page)); c.restoreState()
def cover(c,d):
    c.saveState(); c.setFillColor(TINT); c.rect(0,H-118*mm,W,118*mm,stroke=0,fill=1)
    c.drawImage(ICON, M-4*mm, H-78*mm, 42*mm, 42*mm, mask='auto')
    c.setFillColor(INK); c.setFont('Helvetica-Bold',34); c.drawString(M,H-96*mm,'DriveDex')
    c.setFont('Helvetica',14); c.setFillColor(MUTE); c.drawString(M,H-106*mm,'User guide  ·  Version 2.4'); c.restoreState()
doc=BaseDocTemplate(OUT, pagesize=A4, leftMargin=M, rightMargin=M, topMargin=M, bottomMargin=22*mm, title='DriveDex User Guide', author='DriveDex', subject='How to install and use DriveDex')
doc.addPageTemplates([PageTemplate('cover',[Frame(M,22*mm,CW,H-128*mm-22*mm)],onPage=cover), PageTemplate('page',[Frame(M,22*mm,CW,H-M-22*mm)],onPage=footer)])

s=[NextPageTemplate('page')]
s+=[P("Know what's on every drive, and whether it's backed up.", st(fontName='Helvetica-Bold', fontSize=15, leading=20, spaceAfter=10)),
    P('DriveDex keeps a catalog of every drive and NAS share you connect to your Mac. Once a drive is added, it is re-catalogued automatically whenever you plug it in. Browse and search all your drives (even ones in a drawer), see which drives back up which, get told when something isn\'t backed up, and share the whole catalog between your Macs.'),
    P('DriveDex only records file and folder <b>names, sizes and dates</b>. It never opens or reads the contents of your files.'),
    P('In this guide', h2)]
toc=['Install and update','Adding drives','The drive list','A drive\'s page and browsing','Searching','Setting up your backups','Is everything backed up?','Folders that don\'t need a backup','Backup reminders','Space and duplicates','Shoot mode: memory cards','How it works and its limits','Sharing between your Macs','Settings and shortcuts','Questions and troubleshooting']
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
    side('up', 58*mm, 'DriveDex checks for new versions a few times a day. When one is available you get a notification and this notice at the top of the drive list. Click <b>Install</b>: DriveDex downloads the update, replaces itself and restarts, keeping your catalog. You can also use <b>DriveDex menu &rarr; Check for Updates…</b> or <b>Settings &rarr; Updates</b>.<br/><br/>After an update macOS may ask once more for access to removable volumes; click <b>Allow</b>.'),
    P('This guide is always available in the app under <b>Help &rarr; DriveDex User Guide</b>, and on the download page as <b>DriveDex-Guide.pdf</b>.', small),
    P('Where DriveDex lives', h2),
    P('DriveDex runs in the <b>menu bar</b> (drive icon, top right) and starts when you log in. Closing the window doesn\'t stop it.'),
    PageBreak()]
# 2
s+=[P('2  Adding drives', h1),
    side('new', 58*mm, 'The first time DriveDex sees a drive, it <b>asks before cataloguing it</b>: a notification and a card at the top of the drive list.<br/><br/><b>Catalog it</b> adds the drive. <b>Ignore</b> means never ask again (for example camera cards). App installers (.dmg) are skipped automatically.'),
    P('After that, a known drive is updated automatically whenever you connect it (if its last scan is over an hour old). NAS shares that stay connected are rescanned every 12 hours.'),
    P('<b>Per drive:</b> on a drive\'s <b>Settings</b> tab, <b>Scanning</b> sets when it\'s rescanned: as in Settings (default), every time it\'s connected, every hour, day, week or month, when files change on it, or only when you click Rescan. There you can also ask to be <b>reminded</b> when a drive hasn\'t been updated for 3 days to 3 months.'),
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
    P('The left column has two tabs: <b>Drives</b> (the Overview and all your drives) and <b>Shoots</b> (section 11). Under Drives you see <b>families</b>: each main drive in its own box with its backups indented below. Other drives are listed under <b>Other drives</b>.'),
    side('fam', 60*mm, '&bull; <font color="#2e9d58"><b>Green dot</b></font>: connected to this Mac now.<br/>&bull; <b>HDD / SSD / NAS</b> tag: the kind of drive.<br/>&bull; <b>Bar</b>: how full it is, e.g. <b>2.1 of 4 TB</b>.<br/>&bull; <b>&#9167;</b> (connected drives): eject.<br/>&bull; Hover over a drive to see where it lives, its file count and when it was scanned.<br/>&bull; A line under a main drive appears only when something needs attention (e.g. <b>97.9% backed up</b>).<br/>&bull; <b>Checkmarks</b> (top right): one per backup; green complete, amber 90%+, red less.<br/>&bull; Each backup shows its own fullness bar, how complete it is and how old its catalog is. Folder backups show their folder.<br/>&bull; A backup split over several drives appears as <b>Backup set &middot; N drives</b>, with the combined percentage on that heading and the drives indented below.<br/>&bull; The small <b>&#9662;</b> arrow hides or shows a family\'s backups.'),
    side('compact', 46*mm, '<b>Wider list:</b> drag the border between the drive list and the main area to make the list wider (double-click it to reset). Long names wrap instead of being cut off.<br/><br/><b>Compact list:</b> the button next to "Drives" switches between rows with details and one line per drive (with the capacity), which is handy with many drives. Its icon shows which mode you\'re in.<br/><br/><b>Reorder:</b> drag a family box, or a drive under Other drives, up or down. A blue line shows where it lands. The order syncs to your other Macs.', box=(0,0,546,900)),
    side('dmenu', 42*mm, '<b>Right-click any drive</b> to open it, rescan it, show it in Finder, set its type and role, or <b>Forget drive</b>. Forgetting removes the drive and its catalog from DriveDex (and your other Macs if you share). Nothing on the drive is touched.'),
    PageBreak()]
# 4
s+=[P('4  A drive\'s page and browsing', h1),
    shot('dhead','The top of a drive\'s page: name, type, status, backup status, location, and the three tabs.'),
    table([('<b>Files</b>','Browse the drive\'s folders (opens first).'),('<b>Backups</b>','Everything about backups: what the drive holds (main files / backup), how complete its backups are, the backup reminder, excluded folders and history (sections 6–9). On a backup drive: what it backs up, how complete that is, and the files it\'s missing.'),('<b>Info</b>','Facts only: size and free space, files and folders, last scanned and connected (and on which Mac), format, <b>speed test</b> (read speed from existing files; optional write test with a temporary 2 GB file that\'s deleted right after; note how it was connected, e.g. hub or cable; earlier results kept), <b>scan history</b> (every scan, including failed ones), biggest folders and possible duplicates (collapsed; click to open).'),('<b>Settings</b>','What you can change: type (HDD / SSD / NAS), where the drive lives, <b>Scanning</b> (when it\'s rescanned, reminder) and Forget drive.')], 26*mm),
    Spacer(1,6), P('Three ways to look at files', h2),
    P('Like the Finder, the buttons above the files switch between <b>Icons</b> (big icons, double-click a folder to open it), <b>List</b> (a sortable table with a Backups column) and <b>Columns</b>. DriveDex remembers your choice. The <b>&lsaquo; &rsaquo;</b> buttons on the left, above the files, go <b>back and forward</b> to where you were before, like in a web browser (also &#8984;[ and &#8984;], or &#8984;&larr; and &#8984;&rarr;).'),
    P('Column view', h2),
    shot('cols','Column view. Dots show the backup status of each file, and of everything inside each folder; ⊘ marks an excluded folder, ⇄ a folder linked to another drive.', box=(0,0,1640,350)),
    table([('<b>&darr; &uarr;</b>','Move up and down'),('<b>&rarr;</b> or <b>Return</b>','Open the selected folder'),('<b>&larr;</b>','Back to the parent folder'),('<b>Type a name</b>','Jump to the first item starting with those letters')], 38*mm),
    Spacer(1,6),
    P('The <b>info panel</b> on the right shows the selected item, or the folder you\'re in: its <b>size</b>, for folders how many <b>files and folders</b> it contains (all levels deep), when it was modified, its backup status, any <b>links</b> to other drives (with a <b>Remove</b> button), and a <b>Show in Finder</b> button. The <b>path bar</b> along the bottom always shows where you are; click any part of it to jump back up.'),
    P('Click a drive\'s name to rename it. If the drive is connected, DriveDex offers to rename the drive itself too, so the Finder, Carbon Copy Cloner and DriveDex show the same name. If you rename a drive in the Finder, DriveDex keeps it as the same drive (links, backups and history stay) and asks whether to use the new name, if you had named it differently in DriveDex. Edit where it lives under <b>Settings</b>.'),
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
           'Open a backup drive &rarr; <b>Backups</b> tab &rarr; set <b>This drive holds</b> to <b>Backup</b>.',
           'Under <b>Backs up</b>, tick every main drive it contains. Names like "Samsung T7 Backup" are suggested automatically.']),
    P('A folder as a backup location', h2),
    P('If a drive is backed up into a folder on another drive (for example "Denali" into "Backups/Denali" on the NAS), open that folder and choose the drive under <b>This folder is a backup of</b>, or right-click it &rarr; <b>Use as backup location…</b>.'),
    shot('fbar','Inside a NAS folder: "This folder is a backup of: Denali".'),
    P('A backup split across several drives', h2),
    P('If a drive\'s backup is spread over two drives (for example "Archive" on "Archive Backup A" and "B"), assign both, then on the main drive\'s Backups tab choose <b>Combine with…</b>. They are then checked together as one <b>SET</b>. <b>Split</b> undoes it.'),
    shot('set','A backup set: two drives that together hold one backup.'),
    P('A drive that holds only one folder', h2),
    P('Some drives only hold a copy of one important folder, for example a single project on a small SSD. Either on the <b>main</b> drive, right-click the folder &rarr; <b>This folder is backed up on…</b> and pick the drive with the copy; or on the <b>copy</b>, right-click the folder &rarr; <b>This folder is a copy of the one on…</b> and pick the main drive (DriveDex finds the folder with the same name there). DriveDex then compares <b>only that folder</b> with the drive, so it reads 100% when the folder is fully there. It is labelled <b>only &lt;folder&gt;</b> in the drive list and the Backups table; click <b>compare whole drive</b> to undo. Files in that folder count toward "2+ backups".'),
    P('<b>Changed your mind?</b> Every change to backup links shows a message with an <b>Undo</b> button (or press &#8984;Z, or Edit &rarr; Undo). To remove a link later, right-click the folder &rarr; <b>Remove link: …</b>, or select it and click <b>Remove</b> in the info panel. Folders that are linked show <b>⇄</b>.'),
    PageBreak()]
# 7
s+=[P('7  Is everything backed up?', h1),
    P('Home: Needs attention', h2),
    P('Click <b>Overview</b> at the top of the drive list (its badge counts what needs attention), or the <b>DriveDex</b> title, to come back here from anywhere.'),
    P('The table of all drives below it can be sorted: click <b>Drive</b>, <b>Backup</b>, <b>Where</b>, <b>Used</b>, <b>Files</b> or <b>Last connected</b> (click again to reverse).'),
    shot('home','The home screen lists everything that needs you, with a button to fix each. When all is well it says "Everything is backed up".'),
    P('Marking items as done', h2),
    P('Something that\'s fine as it is (for example files you don\'t need backed up, or a drive that only backs up one folder)? Click <b>&#10003;</b> next to it: it\'s hidden, not fixed, and DriveDex\'s rules stay the same. <b>Show done</b> at the top lists those items again, each with <b>Undo</b>. If the situation changes (more files without a backup, a backup overdue again), the item comes back by itself. Done items sync to your other Macs.'),
    P('The menu-bar icon stays plain; its menu shows which drive is being scanned.'),
    KeepTogether([P('A drive\'s Backups tab', h2),
    shot('backups','Overall bar, one row per backup (or set), reminder, excluded folders and history.', width=CW*0.8)]),
    P('<b>Percentages are by data</b> (how many GB/TB have a copy); the number of files is shown next to them. A backup only shows 100% when nothing at all is missing. The bar shows all data: <font color="#2e9d58"><b>green</b></font> on 2+ backups, <font color="#d9822b"><b>amber</b></font> on exactly 1, <font color="#d33f3f"><b>red</b></font> on none. Each backup row shows how complete it is, when it was last fully <b>in sync</b>, and how old its catalog is. Click the amber <b>&#9888; missing</b> link to see exactly which files that backup lacks.'),
    shot('setmiss','Files missing from one backup set. Click a file to jump to its folder.', width=CW*0.7),
    P('From a backup drive', h2),
    P('Open a backup drive (or a NAS that holds a folder backup): its header says e.g. <b>&#9888; 233 files missing &rsaquo;</b>. Click it for the list of files that backup doesn\'t have. Its <b>Backups</b> tab shows each drive it backs up, how complete it is and when it was last in sync.'),
    note('<b>How matching works:</b> a file counts as backed up when the backup has a file with the same name and size, in any folder. Invisible name differences between a Mac and a NAS (umlauts, special characters) are ignored. Turn on <b>Strict backup check</b> in Settings to also require the same modification date. Each backup is only as current as its last catalog.', colors.HexColor('#fff7e8'), WARN),
    PageBreak()]
# 8 9 10
s+=[P('8  Folders that don\'t need a backup', h1),
    side('fmenu', 44*mm, '<b>Right-click a folder &rarr; Exclude from backup check.</b> It stays visible, greyed out with <b>⊘</b>, and its files (including subfolders) no longer count as missing. Right-click again &rarr; <b>Include in backup check</b> to undo. Excluded folders are also listed on the Backups tab.'),
    P('9  Backup reminders', h1),
    P('If you rotate backup drives (for example two NAS backup drives swapped between home and office), in the <b>Reminder</b> section of the main drive\'s Backups tab, set <b>Remind me when a backup hasn\'t been updated for</b> to 3 days, 1 week, 2 weeks or 1 month. You get a notification (at most once a day), it appears under <b>Needs attention</b>, and the backup is marked <font color="#d9822b"><b>Due</b></font>. Connecting the backup resets it.'),
    P('10  Space and duplicates', h1),
    shot('info','Info tab: biggest folders, and large files that also exist on other (non-backup) drives.', width=CW*0.85),
    PageBreak()]
# 11 shoot mode
s+=[P('11  Shoot mode: memory cards', h1),
    P('For film and photo productions with memory cards, from a single day to a project that runs for a week or more: lots of cards, one main drive and a couple of backups. Click the <b>Shoots</b> tab at the top of the left column &rarr; <b>+ New shoot</b>, give it a name, choose the <b>main drive</b> and the folder you copy the cards into, and the <b>backup drives</b> with their folders. Click a drive button to pick from the list (type a few letters to find it; drives that aren\'t connected are listed too), or <b>Choose in Finder…</b> to click the exact folder, including a folder on the Mac\'s <b>internal drive</b>. For a connected drive, <b>Choose folder…</b> opens the Mac\'s folder window, so new folders appear and you can create one. The folders don\'t need to exist yet, and the backup folders take the main folder\'s name automatically. Click <b>Start shoot</b>.'),
    P('<b>Memory cards never appear in your drive list.</b> DriveDex recognises them by the card reader (the Mac\'s SD slot, USB SD/CF/CFexpress readers), by a camera plugged in directly (DJI, GoPro, Insta360, Sony, Canon and others, when the camera shows its card as a drive), or by camera folders such as DCIM or PRIVATE on drives up to 1 TB. While a shoot is <b>active</b> (a red dot on the Shoots tab), a card shows <b>Add to "your shoot"</b>, in the drive list and on the shoot page: one click and it\'s read as a card of that shoot. Without an active shoot, cards aren\'t catalogued; the notice offers <b>Start a shoot…</b>. To keep a card in your drive list anyway (for example a card you use as storage or backup), click <b>Add to my drives</b> in its notice, or later in <b>Settings &rarr; Memory cards</b>. Nothing is added to a shoot without you clicking, unless you switch on <b>Add memory cards automatically</b> when editing the shoot. Cards catalogued by earlier versions are hidden; <b>Settings &rarr; Memory cards</b> can forget the ones that aren\'t in a shoot. Copy the cards as usual (Finder, or your copy tool). DriveDex never copies, moves or deletes anything.'),
    shot('shoot','A shoot: each card, whether all its files are in the main folder and in each backup, and whether it is safe to format.', width=CW*0.9),
    P('A card is <font color="#2e9d58"><b>safe to format</b></font> when every file on it is in the main folder <b>and</b> in every backup folder: same name and same size, in any subfolder. Connected drives are checked live (just the shoot folder, in seconds); others from their last catalog. The page updates by itself. Click <b>… missing</b> to see which files are still missing where.'),
    P('<b>Deep check.</b> Name and size catch files that were never copied or stopped halfway, but not a damaged copy of the same size. For certainty, click <b>Deep check</b> on a connected card: DriveDex reads every file on the card and every copy in the main and backup folders and compares their contents with xxHash64 fingerprints (the same method Hedge uses). It only reads, never writes. It takes about as long as copying the card, you can keep working meanwhile, and you get a notification when it\'s done. A card that passes shows <font color="#2e9d58"><b>Verified, safe to format</b></font>; any problem is listed file by file. The result stays until the card\'s contents change. For the strictest check, eject and reconnect the drives first, so nothing is read from the Mac\'s memory.'),
    table([('<b>One row per card</b>','A card formatted in DriveDex is recognised when you plug it in again: same row, a new round, no question. A card formatted in the camera is recognised by its name if it has a fixed one (e.g. "CHRIS SD1"; generic names like NO NAME don\'t count). Earlier rounds (files, size, verified or safe, when formatted) are in the <b>Card log</b> below the cards.'),
           ('<b>Export log…</b>','In the <b>Card log</b> bar below the cards. Saves the card log as a spreadsheet file (CSV, opens in Numbers or Excel), starting in the shoot\'s main folder so you can keep it with the footage: every card and round with files, size, result, deep check and formatting.'),
           ('<b>Rename a card</b>','Click its name, e.g. "GoPro 3" or "FX6 A".'),
           ('<b>Add a card</b>','A card that isn\'t listed (for example one DriveDex already knew as a normal drive): <b>+ Add a card…</b> below the list, then pick it or click it in Finder.'),('<b>Format a card</b>','When a connected card is <b>safe to format</b>, click <b>Format…</b>: DriveDex erases it and formats it with the <b>same name</b> (or a new one, up to 11 characters), and ejects it. Shown only for safe cards; without a deep check you have to confirm "format anyway". Camera makers generally recommend formatting in the camera: use this for cameras that work fine with computer-formatted cards (for example action cameras), and format in the camera if one ever complains.'),
           ('<b>Rename a card</b>','<b>Rename…</b> changes the card\'s name without erasing anything, e.g. after formatting it in the camera.'),
           ('<b>Remove a card</b>','The <b>&#10005;</b> button takes a card out of the shoot (it isn\'t added to that shoot again).'),
           ('<b>Pause</b>','New drives are treated normally again until you click <b>Make active</b>.'),
           ('<b>What\'s checked</b>','Only photos (RAW, JPEG, HEIF), videos and audio recordings on the cards. Thumbnails, previews (.THM, .LRV, .LRF), index and database files and XML/SRT sidecars are ignored, since they usually aren\'t copied; the card row shows how many were ignored. You can switch this off when editing the shoot.'),
           ('<b>Mark as done</b>','Keeps the final result of every card, even after the cards are formatted and reused.')], 32*mm),
    note('Shoots are shared between your Macs like everything else. Cards are only added on the Mac where the shoot is active.', colors.HexColor('#eef4ff')),
    PageBreak()]
# 11
s+=[P('12  Sharing between your Macs', h1),
    steps(['On the Mac that knows the most drives: <b>Settings</b> (&#8984;,) &rarr; <b>Share with iCloud Drive</b>, or <b>Use another folder…</b> (Google Drive, Dropbox…).',
           'On every other Mac choose <b>the same</b> option or folder.',
           'After a few minutes all drives appear on every Mac.']),
    shot('sync','Sharing is on. "Sync now" checks for changes immediately.'),
    P('Each Mac keeps a <b>working copy</b> of the catalog (fast, works offline) and exchanges updates through the <b>shared copy</b> in your sync folder (a subfolder called <b>DriveDex</b>).'),
    table([('<b>Shared</b>','Drives and catalogs, names, notes and locations, types, roles, backup assignments (drives, folders, sets), excluded folders, reminders, history, drive order, ignored drives, strict check, and which Mac last saw each drive.'),
           ('<b>Per Mac</b>','Start at login, menu-bar icon, notifications, rescan timing, compact view, and the green "connected" dot (always about this Mac).')], 22*mm),
    Spacer(1,6)]
s+=bullets(['Use a folder your Mac keeps in sync in the background. Don\'t edit or move files inside the DriveDex folder.',
            'A folder on an external drive or NAS works only while it\'s connected.',
            '<b>Stop sharing</b> keeps everything already on this Mac.'])
s+=[PageBreak()]
# 12
s+=[P('13  How it works and its limits', h1),
    P('DriveDex reads each drive\'s <b>table of contents</b> (file names, sizes and dates), never the files themselves. That\'s why scanning is fast and why it works on drives that aren\'t connected.'),
    P('A file counts as <b>backed up</b> when a backup has a file with the <b>same name and size</b>, in any folder (with Strict backup check, also the same date). This catches files that were never copied, copies that stopped halfway and forgotten folders, but:'),
    ]
s+=bullets(['It doesn\'t read file contents: a damaged copy of the same size counts as backed up.',
            'A renamed file counts as missing.',
            'A catalog is a snapshot from the last scan; a backup that hasn\'t been connected for a while may have changed since.'])
s+=[note('<b>DriveDex doesn\'t copy or back up anything.</b> Use a dedicated tool for that: Carbon Copy Cloner, ChronoSync or Time Machine for drive and folder backups, and an offload tool that compares checksums (Hedge OffShoot, ShotPut Pro, Silverstack) for memory cards. DriveDex then shows what\'s on which drive and whether anything was missed.', colors.HexColor('#fff7e8')),
    PageBreak()]
s+=[P('14  Settings and shortcuts', h1),
    table([('<b>Open DriveDex at login</b>','Keep on: DriveDex only catalogs drives while running.'),
           ('<b>General</b>','Open at login, show DriveDex in the menu bar (when off, it still runs; open it from Applications), notifications.'),('<b>Notifications</b>','When scans finish or fail, and for reminders and updates.'),
           ('<b>New drives &amp; scanning</b>','Ask before cataloguing a new drive; default rescan timing; hidden files; disk images; drives never to scan.'),
           ('<b>Default rescan timing</b>','How old a catalog may get before a rescan (1 hour; network shares 12 hours). Each drive can have its own schedule on its Settings tab.'),
           ('<b>Strict backup check</b>','Also compare modification dates (section 7).'),
           ('<b>Never scan these drives</b>','Names to skip. Drives you Ignore are added here.'),
           ('<b>Share between Macs</b>','Section 12.'),('<b>Ask Claude about your drives</b>','<b>Export overview for Claude…</b> saves one readable file about all drives (space, backups, folder structure, what takes the space, duplicates). Drop it into a chat with Claude for advice on storage, naming and backups. Folder names only, unless you tick file names of duplicates.'),('<b>Help / Updates</b>','Open this guide, run the setup guide again, check for and install updates.')], 58*mm),
    P('Keyboard shortcuts', h2),
    table([('<b>&#8984; ,</b>','Settings (press again, or click Settings again, to go back)'),('<b>&#8984; F</b> or <b>/</b>','Search'),('<b>Esc</b>','Clear the search, close a menu'),('<b>&#8984; R</b>','Rescan connected drives'),('<b>&#8984; W</b> / <b>&#8984; Q</b>','Close the window (keeps running) / quit'),('<b>&#8984; ?</b>','Open this user guide'),('<b>Arrow keys</b>','Move around in the Column view'),('<b>&#8984; [</b> / <b>&#8984; ]</b>','Back / forward (also &#8984;&larr; / &#8984;&rarr;, and the Go menu)'),('<b>&#8679;&#8984; O</b>','Overview'),('<b>&#8984; Z</b>','Undo the last backup-link change')], 38*mm),
    PageBreak()]
# 13
s+=[P('15  Questions and troubleshooting', h1)]
faq=[('"The disk couldn\'t be ejected because DriveDex is using it."','DriveDex lets go of a drive the moment you eject it (a scan in progress is stopped and the previous catalog kept), so this shouldn\'t happen any more. You can also eject from DriveDex: the <b>&#9167;</b> button next to each connected drive. If macOS still says "one or more programs may be using it" without naming DriveDex, it\'s usually Spotlight indexing a newly connected drive: wait a minute and try again.'),
     ('A drive shows "macOS blocked access".','Settings tab &rarr; <b>Open Privacy Settings</b> and allow DriveDex (or add it under Full Disk Access). Then <b>Rescan now</b>.'),
     ('I plugged in a drive and nothing happened.','Look for the <b>New drive</b> card. Otherwise check DriveDex is running (menu-bar icon); a drive scanned within the last hour is skipped (use <b>Rescan now</b>).'),
     ('A backup I just finished shows 99.x%.','Rescan the backup (its catalog may predate the end of the backup), then click the amber <b>&#9888; missing</b> link to see which files. Often they are files changed after the backup, like an open Lightroom catalog.'),
     ('My backup is split over two drives and each shows about 50%.','Combine them into a set (section 6).'),
     ('The drives from my other Mac don\'t appear.','Both Macs must use the same sync folder. Click <b>Sync now</b>; the folder should contain files ending in <i>.entries.db</i> and <i>.meta.json</i>.'),
     ('An update failed to install.','The old version stays. Download the latest DriveDex.dmg and install it manually (section 1).'),
     ('Does DriveDex read or upload my files?','No. Only names, sizes and dates, kept on your Macs and in your own sync folder.'),
     ('How do I remove DriveDex?','Quit it, turn off "Open DriveDex at login", drag it to the Bin. To erase the catalog, delete <i>~/Library/Application Support/DriveDex</i> and the DriveDex folder in your sync folder.')]
for q,a in faq: s.append(KeepTogether([P(q, st(fontName='Helvetica-Bold', spaceBefore=6, spaceAfter=2)), P(a)]))
doc.build(s); print('ok')
