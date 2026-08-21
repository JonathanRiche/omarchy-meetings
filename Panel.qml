import QtQuick
import Quickshell.Io
import qs.Commons
import qs.Ui

// Agenda van vandaag als dagkolom, zoals Google Calendar: afspraken op hun
// plek in de tijd, een lijn voor nu, dag-events als balkjes erboven.
//
// Waarom een tijdlijn en geen lijstje: een lijst vertelt je wát er is, een
// kolom vertelt je hoe je dag eruitziet. Het gat tussen twee afspraken is
// informatie, en dat zie je alleen als de ruimte ertussen echt ruimte is.
//
// Structuur volgt de Things-widget: Panel-root voor de lifecycle,
// BarIconButton voor de bar, KeyboardPanel voor het paneel.
//
// Glyphs zijn \u escapes, want letterlijke private-use tekens overleven de
// weg naar schijf niet altijd.
Panel {
  id: root

  moduleName: "jankeesvw.meetings"
  ipcTarget: "jankeesvw.meetings"

  // The script that does the talking sits next to this file, so the plugin
  // runs from wherever it was installed without putting anything on $PATH.
  readonly property string script:
    Qt.resolvedUrl("bin/meetings-widget").toString().replace(/^file:\/\//, "")

  readonly property string iconCalendar: "\uf073"

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  // Altijd een lijst dagen, ook in dagmodus: dan is het er één. Zo tekent de
  // week dezelfde kolom zeven keer in plaats van een tweede weergave.
  property var days: []

  // Vandaag en deze week blijven bewaard tussen twee keer openen door. De
  // timers houden ze vers, dus bij het openen staat er meteen wat en ververst
  // het daarachter; anders kijk je elke keer eerst naar een leeg raster.
  property var todayCache: []
  property var weekCache: []
  property var upcoming: null
  property int nowMinutes: 0
  property bool reachable: true

  // Welke dag er in het paneel staat. 0 is vandaag; de bar blijft altijd over
  // vandaag gaan, ook als je vooruit bladert.
  property int dayOffset: 0

  // Even in Pauls agenda kijken in plaats van je eigen. Alleen voor de dag die
  // je bekijkt; de bar blijft over jouw dag gaan.
  property bool showPaul: false
  // De week is de standaard: die geeft in één blik meer dan een dagkolom, en
  // hij staat altijd klaar doordat hij op de achtergrond wordt opgehaald.
  property bool weekView: true
  property bool loading: false

  // De toggles en alle afspraken vormen samen één ring die tab aflopt, in de
  // volgorde waarin ze op het scherm staan: de week-toggle bovenaan, dan de
  // afspraken, dan de Paul-toggle onderaan. Een dag-event is ook gewoon een
  // afspraak, alleen zonder tijd, dus die staat er net zo goed in.
  property int cursor: -1

  readonly property var ring: {
    var out = []
    for (var d = 0; d < days.length; d++) {
      var day = days[d]
      for (var a = 0; a < day.allday.length; a++) out.push(day.allday[a])
      for (var t = 0; t < day.events.length; t++) out.push(day.events[t])
    }
    return out
  }

  readonly property int ringLength: ring.length + 2
  readonly property bool onWeekToggle: cursor === 0
  readonly property bool onPaulToggle: cursor === ringLength - 1
  readonly property var cursorEvent: (cursor >= 1 && cursor <= ring.length) ? ring[cursor - 1] : null

  // Alle afspraken met een tijd, over alle getoonde dagen. Bepaalt hoe ver de
  // tijdas loopt, zodat elke dag in de week dezelfde as deelt.
  readonly property var allTimed: {
    var out = []
    for (var d = 0; d < days.length; d++)
      for (var t = 0; t < days[d].events.length; t++) out.push(days[d].events[t])
    return out
  }

  readonly property bool emptyDay: {
    for (var d = 0; d < days.length; d++)
      if (days[d].events.length > 0 || days[d].allday.length > 0) return false
    return true
  }
  readonly property string paulCalendar: "Paul - WBSO.ai"
  property string datePath: ""
  property string dateLabel: ""

  // Kleur die de oude waybar-module gaf aan een meeting die bijna begint.
  // Dezelfde kleur trekt de lijn voor nu: het accent van het thema is al van
  // vandaag en van de selectie, en drie dingen in één kleur leest als niets.
  readonly property color urgentFill: "#f7768e"
  readonly property int urgentMinutes: 5

  // Minuten tot de afspraak begint; negatief als hij al loopt.
  readonly property int minutesUntil: upcoming ? upcoming.start_minutes - nowMinutes : 0
  readonly property bool inMeeting: upcoming !== null && minutesUntil <= 0
  readonly property bool almostDue: upcoming !== null && minutesUntil > 0 && minutesUntil <= urgentMinutes

  // "in 25m", "in 1h30m", "25m left" once it is running. The waybar module
  // read the same way, and it beats a bare start time: what you want to know
  // is how much time you have, not what the clock will say.
  function humanDelta(minutes) {
    var m = Math.max(0, minutes)
    if (m < 60) return m + "m"
    return Math.floor(m / 60) + "h" + (m % 60 < 10 ? "0" : "") + (m % 60) + "m"
  }

  readonly property string countdown: {
    if (!upcoming) return ""
    if (inMeeting) return humanDelta(upcoming.end_minutes - nowMinutes) + " left"
    return "in " + humanDelta(minutesUntil)
  }

  // Zichtbare tijdspanne. Ruim genoeg om de werkdag te tonen, en opgerekt
  // als er iets buiten valt, zodat een vroege of late afspraak niet
  // stilletjes wegvalt buiten beeld.
  readonly property int dayStart: {
    var earliest = 7 * 60
    for (var i = 0; i < allTimed.length; i++) earliest = Math.min(earliest, allTimed[i].start_minutes - 30)
    return Math.max(0, Math.min(earliest, nowMinutes - 60))
  }

  readonly property int dayEnd: {
    var latest = 23 * 60
    for (var i = 0; i < allTimed.length; i++) latest = Math.max(latest, allTimed[i].end_minutes + 30)
    return Math.min(24 * 60, Math.max(latest, nowMinutes + 60))
  }

  readonly property int daySpan: Math.max(60, dayEnd - dayStart)

  // Hoogte van één uur. Bepaalt of je duur kunt aflezen: bij te weinig ruimte
  // wordt elk blok even hoog en verdwijnt juist de informatie waarvoor je een
  // tijdlijn tekent in plaats van een lijstje.
  // De tijdas vult precies wat er overblijft, wat er ook op de dag staat. Zo
  // heeft het paneel altijd dezelfde hoogte: een dag die tot middernacht
  // doorloopt krijgt smallere uren, een rij dag-events erbij haalt ze van de
  // as af. Een paneel dat per dag een andere hoogte heeft springt onder je
  // muis vandaan, en bij het openen zou je het zien groeien zodra de data
  // binnenkomt.
  //
  // Alles boven en onder de tijdas wordt opgemeten in plaats van geschat. Die
  // hoogtes hangen niet van de uurhoogte af, dus dit bijt zichzelf niet.
  readonly property int hourHeight: {
    var hours = Math.max(1, daySpan / 60)
    var chrome = dateHeader.height + dayNamesRow.height + alldayRow.height
                 + weekToggle.height + paulToggle.height
                 + content.spacing * 5 + panel.verticalContentInset
                 + Style.space(10)
    var room = panel.maxCardHeight - chrome
    return Math.max(Style.space(16), room / hours)
  }

  // Breedte van de urenkolom links. Die staat buiten de dagen, zodat alle
  // dagen van een week dezelfde tijdas delen.
  readonly property int gutter: Style.space(34)
  readonly property real columnWidth: content.width > 0
    ? (content.width - gutter) / Math.max(1, days.length) : 0

  // Alle dagen krijgen even veel ruimte voor dag-events, ook als er maar één
  // dag iets heeft: anders schuift de tijdas per kolom omhoog of omlaag.
  readonly property int alldayHeight: Style.space(17)

  readonly property string clockText: {
    var h = Math.floor(nowMinutes / 60)
    var m = nowMinutes % 60
    return (h < 10 ? "0" : "") + h + ":" + (m < 10 ? "0" : "") + m
  }
  readonly property int alldayRows: {
    var most = 0
    for (var d = 0; d < days.length; d++) most = Math.max(most, days[d].allday.length)
    return most
  }

  // Panel is een kaal Item, dus zonder deze maat geeft de bar de widget nul
  // breedte en is hij onzichtbaar én onklikbaar.
  readonly property int barSlot: barLabel === ""
    ? Style.bar.iconSlot
    : Math.ceil(labelMetrics.advanceWidth) + Style.space(22)

  TextMetrics {
    id: labelMetrics
    text: root.barLabel
    font.family: root.fontFamily
    font.pixelSize: Style.font.caption
  }
  implicitWidth: bar && bar.vertical ? (bar ? bar.barSize : Style.bar.sizeHorizontal) : barSlot
  implicitHeight: bar && bar.vertical ? barSlot : (bar ? bar.barSize : Style.bar.sizeHorizontal)

  // Titel afgekapt zoals vroeger op 20 tekens: langer duwt de rest van de bar
  // weg voor informatie die je toch in het paneel leest.
  readonly property string barLabel: {
    if (!reachable) return ""
    // Zeg het als de dag leeg is. Een kaal icoon is niet te onderscheiden van
    // een agenda die nog aan het laden is, en juist bij niets meer op de rol
    // wil je dat zeker weten.
    if (!upcoming) return "Nothing planned"
    var title = upcoming.title.length > 20 ? upcoming.title.substring(0, 20) + "…" : upcoming.title
    return title + " @ " + upcoming.start + " " + countdown
  }

  // Loopt er al een ophaal, dan is die achterhaald: je hebt intussen een
  // andere dag of agenda gekozen. Hem laten lopen en zelf niets doen liet het
  // raster leeg staan tot de volgende minuut, dus hij wordt afgebroken en de
  // nieuwe start zodra hij weg is.
  property bool refreshPending: false
  property bool aborting: false

  function refresh() {
    if (listProc.running) {
      refreshPending = true
      aborting = true
      listProc.running = false
      return
    }
    var argv = [root.script, weekView ? "week" : "day", String(dayOffset)]
    if (showPaul) argv.push("--only", paulCalendar)
    listProc.command = argv
    listProc.running = true
    loading = true
  }

  // Het raster staat er voordat gcalcli iets heeft gezegd: dezelfde dagen,
  // dezelfde datums, alleen nog zonder afspraken. Een week die pas verschijnt
  // als de data binnen is voelt traag, terwijl het raster al vaststaat op het
  // moment dat je de knop omzet.
  function skeleton() {
    var today = new Date()
    var base = new Date()
    if (weekView) base.setDate(base.getDate() - ((base.getDay() + 6) % 7) + dayOffset * 7)
    else base.setDate(base.getDate() + dayOffset)

    var locale = Qt.locale("en_US")
    var out = []
    for (var i = 0; i < (weekView ? 7 : 1); i++) {
      var d = new Date(base.getFullYear(), base.getMonth(), base.getDate() + i)
      out.push({
        // Zonder leidende nullen, net als het script, want zo wil Google
        // Calendar het in zijn url.
        date_path: d.getFullYear() + "/" + (d.getMonth() + 1) + "/" + d.getDate(),
        date_label: d.toLocaleDateString(locale, "dddd d MMMM"),
        short_label: d.toLocaleDateString(locale, "ddd d"),
        range_label: d.toLocaleDateString(locale, "d MMM"),
        is_today: d.getFullYear() === today.getFullYear()
                  && d.getMonth() === today.getMonth()
                  && d.getDate() === today.getDate(),
        events: [],
        allday: [],
      })
    }

    days = out
    datePath = out[0].date_path
    dateLabel = weekView ? out[0].range_label + " - " + out[6].range_label
                         : out[0].date_label
  }

  function refreshToday() {
    if (listProc.running) return
    listProc.command = [root.script, "day", "0"]
    listProc.running = true
  }

  // De week op eigen houtje warm houden, los van het paneel. Zeven dagen
  // ophalen kost een paar seconden, en dat wil je niet betalen op het moment
  // dat je hem opent.
  function refreshWeek() {
    if (weekProc.running) return
    weekProc.command = [root.script, "week", "0"]
    weekProc.running = true
  }

  function togglePaul() {
    showPaul = !showPaul
    cursor = ringLength - 1
    skeleton()
    refresh()
  }

  // De hele week in beeld. Het paneel wordt breder en de dagen komen naast
  // elkaar op dezelfde tijdas; de offset telt dan in weken.
  function toggleWeek() {
    weekView = !weekView
    dayOffset = 0
    cursor = 0
    skeleton()
    refresh()
  }

  // Tab loopt rond, inclusief de toggles.
  function tabStep(direction) {
    if (cursor < 0) cursor = direction > 0 ? 0 : ringLength - 1
    else cursor = (cursor + direction + ringLength) % ringLength
  }

  function goDay(delta) {
    dayOffset += delta
    cursor = -1
    // Niet de vorige dag laten staan onder een nieuwe datum, maar ook niet
    // leeg: het lege raster van de nieuwe dag.
    skeleton()
    refresh()
  }

  function applyPayload(text) {
    // Half afgekapte uitvoer van een afgebroken ophaal is geen antwoord.
    if (aborting) return
    try {
      var data = JSON.parse(text)
      reachable = data.ok === true
      var incoming = data.days || []
      var ownAndCurrent = data.offset === 0 && !data.only_calendar
      var isPlainToday = data.mode === "day" && ownAndCurrent
      var isPlainWeek = data.mode === "week" && ownAndCurrent
      if (isPlainToday) todayCache = incoming
      if (isPlainWeek) weekCache = incoming

      // Alleen overnemen als dit antwoord bij is wat je nu staat te bekijken.
      // Een traag antwoord van de vorige dag mag de nieuwe niet overschrijven,
      // en met het paneel dicht blijft de cache staan.
      if (opened && data.mode === (weekView ? "week" : "day")
          && data.offset === dayOffset && !!data.only_calendar === showPaul) {
        days = incoming
      } else if (!opened && (weekView ? isPlainWeek : isPlainToday)) {
        days = incoming
      }

      nowMinutes = data.now_minutes || 0
      datePath = data.date_path || ""
      dateLabel = data.date_label || ""
      // De bar gaat over vandaag: bladeren in het paneel mag hem niet
      // veranderen, anders klopt de aftelling niet meer.
      if (data.is_today && !showPaul) upcoming = data.upcoming || null
      if (cursor >= ringLength) cursor = -1
    } catch (e) {
      reachable = false
    }
  }

  // Er zit geen deelnemers- of video-link in gcalcli's tsv-uitvoer, dus Enter
  // opent de dag in Google Calendar zelf. Dat is waar je toch heen wilt als je
  // meer wilt weten dan tijd en titel.
  // De weekweergave van de getoonde dag, als je niets specifieks aanwijst.
  function openAgenda() {
    if (!bar || datePath === "") return
    close()
    bar.run("omarchy-launch-webapp https://calendar.google.com/calendar/u/0/r/week/" + datePath)
  }

  // Eén dag openen in Google Calendar. De weekweergave staat al voor je, dus
  // als je een dagnaam aanwijst wil je die dag zelf zien.
  function openDay(day) {
    if (!bar || !day) return
    close()
    bar.run("omarchy-launch-webapp https://calendar.google.com/calendar/u/0/r/day/" + day.date_path)
  }

  // Eén afspraak openen. Zit er een Meet-link aan, dan wil je die: je klikt
  // op een gesprek om erin te komen, niet om te lezen wanneer het is. Zonder
  // Meet-link de detailpagina, waar de rest van de afspraak staat.
  function openEvent(event) {
    if (!bar || !event) return
    var url = event.hangout && event.hangout !== "" ? event.hangout : event.link
    if (!url || url === "") { openAgenda(); return }
    close()
    bar.run("omarchy-launch-webapp " + url)
  }

  function openSelected() {
    if (onWeekToggle) { toggleWeek(); return }
    if (onPaulToggle) { togglePaul(); return }
    if (cursorEvent) openEvent(cursorEvent)
    else if (upcoming) openEvent(upcoming)
    else openAgenda()
  }

  // De pijlen lopen dezelfde ring af als tab, maar slaan de toggles over en
  // stoppen aan de uiteinden: op en neer door een lijst hoort niet rond te
  // gaan, en een toggle is geen afspraak.
  function moveSelection(delta) {
    if (ring.length === 0) return
    if (cursorEvent === null) {
      // Eerste keuze is de afspraak waar je nu in zit of naartoe gaat, niet
      // botweg de eerste van de dag.
      var start = 1
      for (var i = 0; i < ring.length; i++) {
        if (ring[i] === upcoming) { start = 1 + i; break }
      }
      cursor = start
      return
    }
    cursor = Math.max(1, Math.min(ring.length, cursor + delta))
  }

  onOpenedChanged: {
    if (opened) {
      // Altijd op vandaag beginnen: waar je gisteren gebleven was is zelden
      // waar je nu heen wilt.
      dayOffset = 0
      showPaul = false
      weekView = true
      cursor = -1
      // Wat er van de laatste keer nog ligt is deze week, en dat is precies
      // wat je nu wilt zien. Is er nog niets, dan in elk geval het lege
      // raster.
      var cached = weekView ? weekCache : todayCache
      if (cached.length > 0) days = cached
      else skeleton()
      refresh()
    }
  }

  Process {
    id: weekProc
    stdout: StdioCollector {
      onStreamFinished: root.applyPayload(text)
    }
  }

  Process {
    id: listProc
    stdout: StdioCollector {
      onStreamFinished: root.applyPayload(text)
    }
    onExited: function(exitCode) {
      root.loading = false
      if (root.aborting) root.aborting = false
      else if (exitCode !== 0) root.reachable = false

      if (root.refreshPending) {
        root.refreshPending = false
        root.refresh()
      }
    }
  }

  // Elke minuut, zodat de nu-lijn meeloopt. De agenda zelf verandert
  // zelden, maar opnieuw ophalen is goedkoop genoeg om ze samen te doen.
  Timer {
    interval: 60000
    running: true
    repeat: true
    triggeredOnStart: true
    // Staat het paneel dicht, dan gaat het om de bar, en die gaat altijd over
    // je eigen dag van vandaag, wat je de vorige keer ook stond te bekijken.
    onTriggered: root.opened ? root.refresh() : root.refreshToday()
  }

  Timer {
    interval: 1800000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refreshWeek()
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    slotSize: root.barSlot
    opticalSize: root.barLabel === "" ? Style.bar.iconCanvas : root.barSlot
    opacity: root.reachable ? 1 : 0.5
    // Loopt de afspraak nu, dan valt de bar op; anders is het een vooruitblik.
    active: root.current !== null
    tooltipText: ""

    iconComponent: Component {
      Item {
        // Bijna tijd: het hele blokje kleurt, zoals de oude module deed. Een
        // kleurtje op de tekst alleen zie je niet vanuit je ooghoek.
        Rectangle {
          anchors.centerIn: parent
          width: barRow.implicitWidth + Style.space(8)
          height: Style.space(18)
          radius: Style.cornerRadius
          visible: root.almostDue
          color: root.urgentFill
        }

        Row {
          id: barRow
          anchors.centerIn: parent
          spacing: Style.space(5)

          // Kalenderkleur, in plaats van het emoji-blokje van vroeger.
          Rectangle {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.upcoming !== null && !root.almostDue
            width: Style.space(7)
            height: Style.space(7)
            radius: width / 2
            color: root.upcoming ? root.upcoming.color : "transparent"
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.upcoming === null
            text: root.iconCalendar
            font.family: root.fontFamily
            font.pixelSize: Style.bar.iconFont
            renderType: Text.NativeRendering
            color: root.foreground
          }

          Text {
            anchors.verticalCenter: parent.verticalCenter
            visible: root.barLabel !== ""
            text: root.barLabel
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            renderType: Text.NativeRendering
            color: root.almostDue ? Color.background
                                  : (root.inMeeting ? root.urgent : root.foreground)
          }
        }
      }
    }

    onPressed: function(b) {
      if (b === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    // Zonder de hulpfunctie gerekend, zodat het omschakelen naar de week de
    // kaart meteen meeneemt in plaats van pas bij de volgende keer openen.
    readonly property int desiredWidth: Style.space(root.weekView ? 1000 : 340)
    contentWidth: Math.min(desiredWidth,
                           panel.availableCardWidth > 0 ? panel.availableCardWidth : desiredWidth)
    // Vaste hoogte, want de uurhoogte vult wat er overblijft: de dag past er
    // altijd helemaal in, hoe laat hij ook doorloopt. Het scherm is alleen de
    // bovengrens voor als er minder ruimte is dan dit.
    readonly property real maxCardHeight: Math.min(Style.space(620),
      availableCardHeight > 0 ? availableCardHeight : Style.space(620))
    contentHeight: panel.fittedContentHeight(content.implicitHeight, maxCardHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onMoveRequested: function(dx, dy) {
        if (dx !== 0) root.goDay(dx)
        else if (dy !== 0) root.moveSelection(dy)
      }
      onTabRequested: function(direction) { root.tabStep(direction) }
      // Alleen activate: Enter stuurt returnRequested en activateRequested
      // allebei, en dan zou een toggle meteen weer terugklappen.
      onActivateRequested: root.openSelected()

      Column {
        id: content
        anchors.fill: parent
        spacing: Style.space(8)

        // Dagkop met bladeren. Links en rechts doen hetzelfde als de pijlen.
        Item {
          id: dateHeader
          width: parent.width
          height: dateText.implicitHeight + Style.space(6)

          Text {
            id: prevArrow
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf053"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.5
            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              onClicked: root.goDay(-1)
            }
          }

          Text {
            id: dateText
            anchors.centerIn: parent
            text: root.dateLabel
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: root.dayOffset === 0 ? 1 : 0.7

            MouseArea {
              id: dateMouse
              anchors.fill: parent
              anchors.margins: -Style.space(4)
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openAgenda()

              PanelToolTip {
                visible: dateMouse.containsMouse
                text: "Open in Google Calendar"
                fontFamily: root.fontFamily
              }
            }
          }

          Text {
            anchors.left: dateText.right
            anchors.leftMargin: Style.space(8)
            anchors.verticalCenter: parent.verticalCenter
            visible: root.loading
            // nf-md-loading, buiten het BMP dus als surrogaatpaar
            text: "\udb82\udd96"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.6

            RotationAnimator on rotation {
              running: root.loading
              from: 0
              to: 360
              duration: 1000
              loops: Animation.Infinite
            }
          }

          Text {
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "\uf054"
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            color: root.foreground
            opacity: 0.5
            MouseArea {
              anchors.fill: parent
              anchors.margins: -Style.space(6)
              onClicked: root.goDay(1)
            }
          }
        }

        // De hele week in één keer. Verandert alleen wat eronder staat; de bar
        // blijft jouw eerstvolgende afspraak van vandaag tonen.
        Toggle {
          id: weekToggle
          width: parent.width
          height: Style.space(26)
          label: "Show the whole week"
          checked: root.weekView
          hasCursor: root.onWeekToggle
          foreground: root.foreground
          fontFamily: root.fontFamily
          titleSize: Style.font.caption
          // Geen kader: de toggle staat hier niet in een instellingenlijst maar
          // aan de rand van een agenda, en een omlijnd vak trekt daar meer
          // aandacht dan het verdient. De vulling komt terug zodra de muis of
          // de cursor erop staat, zodat je nog ziet waar je bent.
          property bool hot: false
          onHovered: function(isHovered) { hot = isHovered }
          color: (hot || hasCursor) ? Style.hoverFillFor(root.foreground, Color.accent)
                                    : "transparent"
          borderSpec: Border.flat("transparent", 0)
          onClicked: root.toggleWeek()
        }

        // Kolomkoppen. In dagmodus staat de dag al in de titelbalk.
        Row {
          id: dayNamesRow
          width: parent.width
          height: visible ? implicitHeight : 0
          visible: root.weekView && root.reachable

          Item { width: root.gutter; height: 1 }

          Repeater {
            model: root.days

            Item {
              id: dayHeader
              required property var modelData
              width: root.columnWidth
              height: dayName.implicitHeight + Style.space(4)

              MouseArea {
                id: dayHeaderMouse
                anchors.fill: parent
                hoverEnabled: true
                cursorShape: Qt.PointingHandCursor
                onClicked: root.openDay(dayHeader.modelData)

                PanelToolTip {
                  visible: dayHeaderMouse.containsMouse
                  text: dayHeader.modelData.date_label + "\nOpen in Google Calendar"
                  fontFamily: root.fontFamily
                }
              }

              Rectangle {
                anchors.centerIn: parent
                visible: modelData.is_today
                width: dayName.implicitWidth + Style.space(12)
                height: dayName.implicitHeight + Style.space(3)
                radius: height / 2
                color: Color.accent
              }

              Text {
                id: dayName
                anchors.centerIn: parent
                text: modelData.short_label
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: modelData.is_today ? Color.background : root.foreground
                opacity: modelData.is_today ? 1 : 0.6
              }
            }
          }
        }

        // Dag-events horen niet in de tijdkolom: ze duren de hele dag en
        // zouden alles overschaduwen. Google zet ze om dezelfde reden apart
        // bovenaan.
        Row {
          id: alldayRow
          width: parent.width
          height: visible ? implicitHeight : 0
          visible: root.alldayRows > 0 && root.reachable

          Item { width: root.gutter; height: 1 }

          Repeater {
            model: root.days

            Item {
              id: alldayColumn
              required property var modelData
              width: root.columnWidth
              height: root.alldayRows * root.alldayHeight

              Column {
                anchors.fill: parent
                anchors.rightMargin: root.weekView ? Style.space(2) : 0
                spacing: Style.space(2)

                Repeater {
                  model: alldayColumn.modelData.allday

                  // Zelfde vorm als de blokken in de kolom: volle
                  // kalenderkleur als rand, getinte vulling. Zonder die rand
                  // zijn ze nagenoeg grijs en zie je niet bij welke agenda ze
                  // horen.
                  Rectangle {
                    id: allDayBlock
                    required property var modelData
                    width: parent.width
                    height: root.alldayHeight - Style.space(2)
                    radius: Style.cornerRadius
                    readonly property color tint: Qt.lighter(modelData.color, 1.25)
                    color: Qt.rgba(tint.r, tint.g, tint.b, 0.24)
                    border.color: Color.accent
                    border.width: root.cursorEvent === modelData ? 1 : 0

                    Rectangle {
                      anchors.left: parent.left
                      anchors.top: parent.top
                      anchors.bottom: parent.bottom
                      width: Style.space(3)
                      radius: width / 2
                      color: allDayBlock.modelData.color
                    }

                    MouseArea {
                      id: allDayMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.cursor = 1 + root.ring.indexOf(allDayBlock.modelData)
                        root.openEvent(allDayBlock.modelData)
                      }

                      PanelToolTip {
                        visible: allDayMouse.containsMouse
                        text: allDayBlock.modelData.title + "\nAll day \u00b7 " + allDayBlock.modelData.calendar
                        fontFamily: root.fontFamily
                      }
                    }

                    Text {
                      anchors.verticalCenter: parent.verticalCenter
                      anchors.left: parent.left
                      anchors.right: parent.right
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(6)
                      text: allDayBlock.modelData.title
                      elide: Text.ElideRight
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.foreground
                      opacity: 0.85
                    }
                  }
                }
              }
            }
          }
        }

        // De tijdas, met daarop één kolom per dag.
        Item {
          id: timeline
          width: parent.width
          // Een strook onder de as, zodat het laatste uurlabel er helemaal
          // op staat in plaats van half over de rand.
          readonly property real spanHeight: root.daySpan / 60 * root.hourHeight
          height: spanHeight + Style.space(10)
          visible: root.reachable

          function yFor(minutes) {
            return (minutes - root.dayStart) / root.daySpan * spanHeight
          }

          // Uurlijnen met hun label. Alleen hele uren binnen de zichtbare
          // spanne, want halve uren maken het bij deze hoogte onleesbaar.
          Repeater {
            model: Math.floor(root.dayEnd / 60) - Math.ceil(root.dayStart / 60) + 1

            Item {
              required property int index
              readonly property int hour: Math.ceil(root.dayStart / 60) + index

              width: timeline.width
              height: 1
              y: timeline.yFor(hour * 60)

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                width: root.gutter - Style.space(6)
                horizontalAlignment: Text.AlignRight
                // Wijkt voor de klok: twee tijden over elkaar leest als geen
                // van beide.
                visible: Math.abs(root.nowMinutes - hour * 60) * root.hourHeight / 60 > Style.space(9)
                text: String(hour).padStart(2, "0") + ":00"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: root.foreground
                opacity: 0.4
              }

              Rectangle {
                anchors.left: parent.left
                anchors.leftMargin: root.gutter
                anchors.right: parent.right
                height: 1
                color: root.foreground
                opacity: 0.12
              }
            }
          }

          Row {
            x: root.gutter
            width: timeline.width - root.gutter
            height: timeline.spanHeight

            Repeater {
              model: root.days

              Item {
                id: dayColumn
                required property var modelData
                required property int index
                width: root.columnWidth
                height: timeline.spanHeight

                // Vandaag krijgt een eigen baan, zodat je hem in een week
                // ziet staan zonder eerst de dagnamen te lezen.
                Rectangle {
                  anchors.fill: parent
                  visible: root.weekView && dayColumn.modelData.is_today
                  color: Color.accent
                  opacity: 0.13
                }

                // Randen links en rechts, zodat de kolom van vandaag een
                // begin en een eind heeft in plaats van alleen een tint.
                Repeater {
                  model: (root.weekView && dayColumn.modelData.is_today) ? 2 : 0

                  Rectangle {
                    required property int index
                    x: index === 0 ? 0 : dayColumn.width - width
                    width: 1
                    height: dayColumn.height
                    color: Color.accent
                    opacity: 0.5
                  }
                }

                // Scheiding tussen de dagen. Zonder streep lopen twee volle
                // dagen visueel in elkaar over.
                Rectangle {
                  visible: root.weekView && dayColumn.index > 0
                  width: 1
                  height: parent.height
                  color: root.foreground
                  opacity: 0.12
                }

                Rectangle {
                  visible: dayColumn.modelData.is_today
                           && root.nowMinutes >= root.dayStart && root.nowMinutes <= root.dayEnd
                  y: timeline.yFor(root.nowMinutes) - 1
                  width: dayColumn.width
                  height: 2
                  color: root.urgentFill
                  z: 11
                }

                Repeater {
                  model: dayColumn.modelData.events

                  Rectangle {
                    id: block
                    required property var modelData

                    readonly property bool today: dayColumn.modelData.is_today
                    readonly property bool isNow: today
                                                  && root.nowMinutes >= modelData.start_minutes
                                                  && root.nowMinutes < modelData.end_minutes
                    readonly property bool isPast: today && root.nowMinutes >= modelData.end_minutes

                    // Overlappende afspraken staan naast elkaar; het script
                    // deelt de kolommen in. Ze krijgen allemaal dezelfde
                    // breedte, wat bij een lange afspraak met korte overleggen
                    // ernaast het rustigst leest.
                    readonly property int lane: modelData.columns > 0 ? modelData.columns : 1
                    readonly property int inset: root.weekView ? Style.space(2) : Style.space(4)
                    readonly property real laneWidth: (dayColumn.width - inset) / lane

                    x: inset + modelData.column * laneWidth
                    width: laneWidth - (lane > 1 ? Style.space(2) : 0)
                    y: timeline.yFor(modelData.start_minutes)
                    // Een kort overleg mag niet tot een streepje krimpen, dus
                    // een ondergrens waarop de titel nog past.
                    height: Math.max(Style.space(14),
                                     timeline.yFor(modelData.end_minutes) - timeline.yFor(modelData.start_minutes) - 2)
                    radius: Style.cornerRadius
                    // Een lichtere variant van de kalenderkleur als vulling:
                    // de volle kleur zit al in de rand, en een blok daarin
                    // maakt de titel erop onleesbaar. Opgelicht in plaats van
                    // alleen doorzichtiger, want doorzichtig op een donkere
                    // achtergrond levert grijs op in plaats van kleur.
                    readonly property color tint: Qt.lighter(modelData.color, 1.25)
                    color: Qt.rgba(tint.r, tint.g, tint.b, isNow ? 0.5 : 0.28)
                    opacity: isPast ? 0.4 : 1
                    border.width: root.cursorEvent === modelData ? 1 : 0
                    border.color: Color.accent

                    Rectangle {
                      anchors.left: parent.left
                      anchors.top: parent.top
                      anchors.bottom: parent.bottom
                      width: Style.space(3)
                      radius: width / 2
                      color: block.modelData.color
                    }

                    MouseArea {
                      id: blockMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.cursor = 1 + root.ring.indexOf(block.modelData)
                        root.openEvent(block.modelData)
                      }

                      // De begin- en eindtijd staan niet altijd in het blok:
                      // bij overlap is er geen ruimte voor, en een kort blok
                      // toont alleen de titel. Hover vult dat aan.
                      PanelToolTip {
                        visible: blockMouse.containsMouse
                        text: block.modelData.start + " \u2013 " + block.modelData.end
                              + "\n" + block.modelData.title
                        fontFamily: root.fontFamily
                      }
                    }

                    Text {
                      anchors.fill: parent
                      anchors.leftMargin: Style.space(8)
                      anchors.rightMargin: Style.space(4)
                      anchors.topMargin: Style.space(3)
                      anchors.bottomMargin: Style.space(3)
                      // In de week is er geen ruimte voor de tijd ernaast, en
                      // die lees je daar toch van de as af.
                      text: (block.lane > 1 || root.weekView)
                            ? block.modelData.title
                            : block.modelData.start + "  " + block.modelData.title
                      elide: Text.ElideRight
                      wrapMode: block.height > Style.space(30) ? Text.Wrap : Text.NoWrap
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      color: root.foreground
                    }
                  }
                }
              }
            }
          }

          // Nu. Bewust bovenop alles, want dit is de regel waar je oog als
          // eerste heen moet.
          Item {
            width: timeline.width
            height: 1
            y: timeline.yFor(root.nowMinutes)
            visible: root.nowMinutes >= root.dayStart && root.nowMinutes <= root.dayEnd
            z: 10

            // De klok links, op de plek van het uurlabel dat hij toch
            // overschrijft. Zo hoef je de lijn niet terug te rekenen naar een
            // tijd.
            Rectangle {
              anchors.right: parent.left
              anchors.rightMargin: -root.gutter + Style.space(4)
              anchors.verticalCenter: parent.verticalCenter
              width: nowLabel.implicitWidth + Style.space(8)
              height: nowLabel.implicitHeight + Style.space(2)
              radius: Style.cornerRadius
              color: root.urgentFill

              Text {
                id: nowLabel
                anchors.centerIn: parent
                text: root.clockText
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                color: Color.background
              }
            }

            Rectangle {
              anchors.left: parent.left
              anchors.leftMargin: root.gutter
              anchors.right: parent.right
              height: root.weekView ? 1 : 2
              y: root.weekView ? 0 : -1
              color: root.urgentFill
              opacity: root.weekView ? 0.35 : 1
            }
          }
        }

        // Even in andermans agenda kijken. Onderaan, want het is de
        // uitzondering: negen van de tien keer wil je je eigen dag zien.
        Toggle {
          id: paulToggle
          width: parent.width
          height: Style.space(24)
          label: "Show Paul's calendar"
          checked: root.showPaul
          hasCursor: root.onPaulToggle
          foreground: root.foreground
          fontFamily: root.fontFamily
          titleSize: Style.font.caption
          // Geen kader: de toggle staat hier niet in een instellingenlijst maar
          // aan de rand van een agenda, en een omlijnd vak trekt daar meer
          // aandacht dan het verdient. De vulling komt terug zodra de muis of
          // de cursor erop staat, zodat je nog ziet waar je bent.
          property bool hot: false
          onHovered: function(isHovered) { hot = isHovered }
          color: (hot || hasCursor) ? Style.hoverFillFor(root.foreground, Color.accent)
                                    : "transparent"
          borderSpec: Border.flat("transparent", 0)
          onClicked: root.togglePaul()
        }

        Text {
          width: parent.width
          visible: !root.reachable || (root.days.length > 0 && root.emptyDay)
          text: !root.reachable ? "Calendar unreachable"
                                : (root.showPaul ? "Nothing on Paul's calendar"
                                                 : "Nothing planned")
          horizontalAlignment: Text.AlignHCenter
          font.family: root.fontFamily
          font.pixelSize: Style.font.body
          color: root.foreground
          opacity: 0.6
        }
      }
    }
  }
}
