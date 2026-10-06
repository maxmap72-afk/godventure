# Guida ad Avventura

Avventura è un motore per avventure grafiche punta-e-clicca nello stile di SCUMM e AGS,
costruito come plugin per **Godot 4.4 o successivo**. Questa guida spiega come creare un
gioco, dal primo hotspot fino all'esportazione. Il gioco dimostrativo *Il Segreto del Faro*
(cartella `game/`) usa quasi tutto ciò che è descritto qui: tienilo aperto come esempio.

**Indice**

1. [Concetti](#1-concetti)
2. [Struttura di un gioco](#2-struttura-di-un-gioco)
3. [Il primo gioco in dieci minuti](#3-il-primo-gioco-in-dieci-minuti)
4. [Stanze](#4-stanze)
5. [Hotspot](#5-hotspot)
6. [Personaggi](#6-personaggi)
7. [Oggetti dell'inventario](#7-oggetti-dellinventario)
8. [Il linguaggio AdvScript](#8-il-linguaggio-advscript)
9. [Dialoghi](#9-dialoghi)
10. [Interfacce di gioco](#10-interfacce-di-gioco)
11. [Salvataggi](#11-salvataggi)
12. [GDScript: quando serve più potenza](#12-gdscript-quando-serve-più-potenza)
13. [Test, console e strumenti](#13-test-console-e-strumenti)
14. [Lavorare con Claude Code](#14-lavorare-con-claude-code)
15. [Impostazioni del progetto](#15-impostazioni-del-progetto)
16. [Esportare e tradurre](#16-esportare-e-tradurre)
17. [Importare un gioco AGS](#17-importare-un-gioco-ags)

---

## 1. Concetti

| Concetto | Cos'è | Dove si definisce |
|---|---|---|
| **Stanza** | un luogo: sfondo, area calpestabile, cose con cui interagire | scena `game/rooms/<id>/<id>.tscn` + script `<id>.adv` |
| **Hotspot** | qualunque cosa cliccabile: una porta, un cartello, un'uscita | nodo `AdvHotspot` nella scena della stanza |
| **Personaggio** | il protagonista o un PNG; cammina, parla, si anima | dichiarazione in `characters.adv`, scena facoltativa |
| **Oggetto** | ciò che finisce nell'inventario | dichiarazione in `items.adv`, icona in `game/items/` |
| **Dialogo** | albero di scelte, come in Monkey Island | blocco `dialog` in un file `.adv` |
| **Script** | cosa succede quando il giocatore fa qualcosa | file `.adv` (AdvScript) |

Il giocatore compie **azioni**: un *verbo* su un *bersaglio*, eventualmente con un
*oggetto* (`look cartello`, `use chiave on porta`, `give vermi to beppe`). Il motore cerca
lo script che gestisce quell'azione (`on look cartello:`) e lo esegue. Se non c'è, usa
le scorciatoie dell'hotspot (descrizione, raccolta, uscita) o le risposte generiche.

## 2. Struttura di un gioco

```
project.godot
addons/avventura/            il motore (non serve toccarlo)
game/
  game.adv                   titolo, protagonista, stanza iniziale, variabili, risposte generiche
  characters.adv             personaggi, i loro script e i loro dialoghi
  items.adv                  oggetti dell'inventario
  items/<id>.svg|png         icone degli oggetti (facoltative)
  rooms/<id>/<id>.tscn       scena della stanza
  rooms/<id>/<id>.adv        script della stanza (vale solo lì)
  characters/<id>/<id>.tscn  scena del personaggio (facoltativa)
  audio/<nome>.ogg|wav|mp3   suoni e musiche
  tests/*.advtest            soluzioni automatiche (test)
  title.svg|png              sfondo del menu iniziale (facoltativo)
  game.gd                    funzioni GDScript richiamabili dagli script (facoltativo)
```

Le convenzioni sui nomi fanno il lavoro di configurazione: una stanza si chiama come la sua
cartella, lo script di una stanza sta accanto alla sua scena, un'icona si chiama come
l'oggetto. Gli id sono in `snake_case` (minuscolo, niente spazi).

## 3. Il primo gioco in dieci minuti

1. **Apri il progetto** in Godot 4.4+. Il plugin è già attivo: in alto accanto a 2D, 3D,
   Script trovi la scheda **Avventura**.
2. **Crea una stanza**: pulsante **+ Stanza**, id `cucina`, nome `Cucina`. Si aprono la scena
   e il suo script.
3. **Sfondo**: trascina un'immagine 1280×720 sulla proprietà *Texture* del nodo
   `Background`. Senza sfondo la stanza usa un colore: puoi prototipare senza grafica.
4. **Area calpestabile**: seleziona `WalkArea` e modifica il poligono con gli strumenti della
   barra 2D. È il pavimento dove possono stare i *piedi* dei personaggi.
5. **Un hotspot**: aggiungi un nodo `AdvHotspot` (si chiama per esempio `Frigo`), dagli un
   figlio `CollisionPolygon2D` e disegna la forma cliccabile. Nell'ispettore scrivi
   *Display Name* `Frigorifero` e *Description* `Un frigorifero che ronza.`: già così
   il clic destro funziona, senza scrivere script.
6. **Uno script**: nella scheda Avventura apri `rooms/cucina/cucina.adv` e scrivi:

   ```
   on use frigo:
       nina: Vediamo cosa c'è dentro...
       inventory add latte
       nina: Del latte!
   ```

   e in `items.adv` aggiungi `item latte "Latte"`.
7. **Collega la stanza**: in un'altra stanza metti un hotspot con *Exit To* = `cucina`; in
   `cucina.tscn` aggiungi un `Marker2D` chiamato come la stanza di provenienza: è lì che
   comparirà il protagonista.
8. **Prova**: *Gioca da questa stanza* (o F6 sulla scena della stanza). **Controlla**
   segnala errori e riferimenti sbagliati con file e riga.

## 4. Stanze

La radice della scena è un nodo **AdvRoom**:

| Proprietà | Significato |
|---|---|
| `room_id` | id usato negli script; vuoto = nome del file |
| `display_name` | nome mostrato nei salvataggi |
| `size` | dimensioni; zero = quelle dello sfondo |
| `music` | musica da `game/audio/` suonata all'ingresso |
| `background_color` | colore usato se non c'è un `Background` |
| `far_y`, `far_scale`, `near_y`, `near_scale` | prospettiva: i personaggi rimpiccioliscono verso `far_y` |
| `camera_follow` | la telecamera segue il protagonista (stanze più larghe dello schermo) |

Figli tipici:

- **Background** – uno `Sprite2D` con `centered = false` e `z_index = -100`.
- **AdvWalkArea** – un poligono (è un `Polygon2D`, quindi si disegna con l'editor dei poligoni).
  I suoi figli `Polygon2D` sono **ostacoli** (un tavolo, uno scoglio). Si possono avere più aree:
  quelle che si toccano vengono unite. `blocked = true` trasforma un'area in ostacolo;
  `enabled = false` la disattiva (un ponte che non c'è ancora): negli script `enable ponte` /
  `disable ponte`. Il percorso più breve viene calcolato automaticamente.
- **Punti d'ingresso** – nodi `Marker2D` o `AdvEntry` (che ha anche la direzione in cui
  guardare). `goto molo at pontile` porta il protagonista al marker `pontile`; senza `at`
  si usa il marker chiamato come la stanza da cui si arriva, poi `default`.
- **Hotspot e personaggi** – come figli diretti della stanza vengono ordinati in profondità
  secondo la loro Y (chi è più in basso sta davanti). Per elementi sempre in primo piano
  usa uno `z_index` positivo.

- **Regioni** – nodi `AdvRegion` (poligoni invisibili sul pavimento): quando il protagonista
  ci entra o ne esce partono `on walk_onto ID:` e `on walk_off ID:` (come i *WalksOnto* di
  AGS). Si attivano solo quando il gioco non sta eseguendo uno script; `enable`/`disable`
  le accendono e spengono.

Eventi della stanza, nello script della stanza:

```
on setup:      # la stanza è caricata ma non ancora visibile (anche dopo un caricamento)
on enter:      # il protagonista è entrato (non dopo un caricamento)
on exit:       # sta per uscire
```

`setup` deve solo sistemare l'aspetto (può essere eseguito più volte); le scene
d'ingresso vanno in `enter`, spesso con `if first:`.

## 5. Hotspot

Un **AdvHotspot** è un `Area2D`. La forma cliccabile è un figlio `CollisionPolygon2D` (o
`CollisionShape2D`); in mancanza si usa il rettangolo di un figlio `Sprite2D` /
`AnimatedSprite2D` (con `pixel_perfect` solo i pixel non trasparenti).

| Proprietà | Significato |
|---|---|
| `hotspot_id` | id per gli script; vuoto = nome del nodo in snake_case (`VecchioBaule` → `vecchio_baule`) |
| `display_name` | nome mostrato al passaggio del mouse |
| `description` | frase detta dal protagonista su *guarda* se non c'è uno script |
| `default_verb` | azione del clic principale (interfaccia a due clic) o del clic destro (SCUMM) |
| `walk_to` | punto dove si ferma il protagonista (relativo); oppure un figlio `Marker2D` chiamato `WalkTo` |
| `face` | direzione in cui guardare all'arrivo |
| `walk_before` | se il protagonista cammina fino all'hotspot prima di agire |
| `interactive` | cliccabile o no (negli script: `enable` / `disable`) |
| `pickup_item` | scorciatoia: *raccogli* lo nasconde e aggiunge questo oggetto all'inventario |
| `exit_to`, `exit_entry` | scorciatoia: è un'uscita verso quella stanza (e quel punto d'ingresso) |
| `click_priority` | vince quando due hotspot si sovrappongono (a parità vince il più piccolo) |

**Stati visivi.** `state porta aperta` fa partire l'animazione `aperta` di un figlio
`AnimatedSprite2D` o `AnimationPlayer`, e mostra i figli chiamati `state_aperta`
nascondendo gli altri `state_...`. Nel demo il barile ha due sprite, `state_chiuso` e
`state_aperto`. Lo stato viene salvato e ripristinato.

**Oggetti che parlano.** Anche un hotspot può parlare: `gabbiano: Crà!` mostra il testo
sopra il gabbiano.

**Mostrare e nascondere.** `show`, `hide`, `enable`, `disable` e `state` funzionano su
hotspot, aree calpestabili e qualunque nodo per nome (per esempio uno sprite `Buca`), anche
in altre stanze (`hide barca in molo`): il motore se lo ricorda.

## 6. Personaggi

Si dichiarano in `game/characters.adv`:

```
character beppe "Beppe":
    color = #ffd166      # colore del testo (e del manichino)
    body = #e9b949       # manichino: vestiti
    hair = #d9d9d9       # manichino: capelli
    skin = #f5cfa9       # manichino: pelle
    speed = 180          # pixel al secondo
    height = 150         # altezza (manichino, area cliccabile, posizione del fumetto)
    room = molo          # dove si trova a inizio partita
    at = posto_beppe     # in quale punto (marker o hotspot)
    description = Un vecchio pescatore.
```

Il protagonista è quello indicato da `player` in `game.adv`.

**Grafica.** Senza una scena il personaggio è un **manichino disegnato dal motore** (cammina,
parla, raccoglie): si può finire un gioco intero prima di disegnare. Per la grafica vera crea
`game/characters/<id>/<id>.tscn` con radice `AdvCharacter` e un figlio `AnimatedSprite2D`
(il pulsante **+ Personaggio** con "crea scena" prepara tutto). Nomi delle animazioni:

| Animazione | Quando |
|---|---|
| `idle_down`, `idle_up`, `idle_side` | fermo (`side` guarda a destra; `side_faces_left` se è il contrario) |
| `walk_down`, `walk_up`, `walk_side` | cammina |
| `talk_down`, `talk_side`, ... | parla (`talk_felice` per `beppe(felice): ...`) |
| `idle_left` / `idle_right` ecc. | alternative a `side`, se le hai disegnate |
| qualunque altro nome | `anim beppe balla` |

Se manca una variante il motore ripiega su quella più vicina (`walk_left` → `walk_side`
specchiata → `walk_down` → `walk` → `idle`). Per l'animazione di raccolta usa `pickup`.

**Due tipi di PNG.** Un personaggio *dichiarato* in `characters.adv` è gestito dal motore:
può cambiare stanza (`place beppe in faro at scala`), la sua posizione viene salvata e può
diventare il protagonista (`control beppe`, stile Maniac Mansion). Un `AdvCharacter` messo
direttamente nella scena di una stanza è invece un PNG *locale* di quella stanza (il
granchio del demo).

## 7. Oggetti dell'inventario

```
item chiave "Chiave del faro"
item vermi "Vermi":
    description = Un pugno di vermi.   # risposta a "guarda" senza script
    icon = res://arte/vermi.png        # facoltativo: di default game/items/vermi.svg|png|webp
    color = #c9a36d                    # colore del segnaposto se manca l'icona
```

Senza icona viene disegnato un segnaposto colorato con l'iniziale. Script tipici:

```
on look chiave:                 # guardare un oggetto dell'inventario
    nina: Una grossa chiave di ferro.
on use pala:                    # usare un oggetto da solo (interfaccia SCUMM)
    nina: Devo decidere dove scavare.
on use vermi on pala:           # combinare due oggetti (vale in entrambi i versi)
    nina: La pala non ha fame.
on use chiave on porta:         # oggetto su un hotspot
on give vermi to beppe:         # dare a un personaggio (anche "usa" su un personaggio lo prova)
```

## 8. Il linguaggio AdvScript

AdvScript è pensato per chi scrive storie: si legge come una sceneggiatura. Si basa
sull'**indentazione** come GDScript e Python (4 spazi consigliati). I commenti iniziano con
`#` seguito da uno spazio (`#ffcc00` è un colore, non un commento).

### 8.1 Blocchi di primo livello

```
title "Il Segreto del Faro"        # titolo del gioco
player nina                        # protagonista
start spiaggia at default          # stanza (e punto) iniziale
var monete = 0                     # variabile con il suo valore iniziale
item ... / character ...           # dichiarazioni (vedi sopra)

on EVENTO:                         # start (in game.adv), enter/setup/exit (stanze)
on VERBO BERSAGLIO:                # on look cartello:
on VERBO OGGETTO on BERSAGLIO:     # on use chiave on porta:  (anche with / to / in / at)
dialog NOME:                       # vedi capitolo 9
function NOME(parametri):          # sequenze riutilizzabili: call NOME(valori)
```

**Verbi.** Quelli standard sono `walk`, `look`, `use`, `talk`, `pick`, `open`, `close`,
`push`, `pull`, `give`; puoi inventarne altri (`on lick francobollo:`) e usarli come verbo
predefinito di un hotspot o nell'interfaccia SCUMM.

**Jolly.** `*` significa "qualunque": `on look *:` (guardare qualunque cosa),
`on use * on porta:` (qualunque oggetto sulla porta), `on * *:` (qualunque azione).

**Quale script vince.** Per `use chiave on porta` il motore prova in ordine:
`on use chiave on porta` → `on use porta on chiave` (utile per combinare due oggetti) →
`on use * on porta` → `on use chiave on *` → `on use * on *` → `on * *`. Per un'azione senza
oggetto: `on look cartello` → scorciatoie dell'hotspot (descrizione, uscita, raccolta) →
`on * cartello` → `on look *` → `on * *`. A ogni passo lo script della **stanza** vince su
quello globale. Usare un oggetto su un personaggio prova anche `on give OGGETTO to PERSONAGGIO`.

**Variabili locali di uno script:** `verb`, `target`, `item` (l'azione), `times` (quante
volte questo script è già stato eseguito) e `first` (vero la prima volta).

### 8.2 Istruzioni

| Istruzione | Esempio | Note |
|---|---|---|
| battuta | `nina: Ciao!` · `beppe(felice): "Evviva!"` | `narrator:` per il narratore; `{espressioni}` nel testo |
| `walk` | `walk to porta` · `walk beppe to 400, 520` · `walk to barca nowait` · `walk beppe by 100, -20` | `nowait` non aspetta l'arrivo; `by` sposta rispetto a dove si trova; `anywhere` ignora le aree calpestabili |
| `face` | `face left` · `face beppe nina` | left/right/up/down o un bersaglio |
| `anim` | `anim scava` · `anim beppe balla loop` · `anim idle` | `nowait`, `loop`; `idle` ferma |
| `wait` | `wait 1.5` | secondi |
| `set` | `set monete += 1` · `set nome = "Nina"` | `=`, `+=`, `-=` |
| `if` / `elif` / `else` | `if has(chiave) and not faro_aperto:` | |
| `while` | `while tentativi < 3:` | |
| `inventory` | `inventory add chiave` · `inventory remove vermi` · `inventory add nota to beppe` | |
| `pickup` | `pickup pala` · `pickup cassa as martello` | cammina, raccoglie, nasconde, aggiunge |
| `show` / `hide` | `show buca` · `hide barca in molo` · `show alba fade 3` | hotspot, nodi, in altre stanze; `fade N`: dissolvenza in N secondi |
| `enable` / `disable` | `disable porta` · `enable ponte` | interattività, aree calpestabili |
| `state` | `state barile aperto` · `state faro acceso in spiaggia` | stato visivo salvato |
| `goto` | `goto faro` · `goto molo at pontile` · `goto molo at 240, 350` | cambia stanza (anche in un punto preciso) |
| `place` | `place beppe at barile` · `place beppe in faro at scala` · `place beppe in faro at 600, 500` | sposta un personaggio |
| `control` | `control beppe` | cambia protagonista |
| `dialog` | `dialog beppe` | apre un dialogo |
| `option` | `option on beppe.vermi` · `option off beppe.faro` | attiva/disattiva opzioni |
| `end` / `back` | `end` | chiude il dialogo / torna al dialogo precedente |
| `stop` | `stop` | interrompe lo script (o la funzione) |
| `call` | `call aiuto(2)` · `call apri_botola()` | funzione AdvScript o GDScript |
| `cutscene:` | blocco | nasconde l'interfaccia; Esc la salta |
| `bg:` | blocco | eseguito in sottofondo, senza fermare il gioco |
| `random:` · `cycle:` · `sequence:` | blocco di alternative | una riga a caso / a turno / in sequenza fino all'ultima |
| `once:` | blocco | solo la prima volta |
| `do:` | blocco | raggruppa più righe (per esempio come alternativa di `random:`) |
| `sound` / `music` | `sound porta` · `music tema` · `music stop` | file in `game/audio/` |
| `video` | `video intro` | filmato a schermo intero da `game/video/intro.ogv`; clic o Esc lo saltano |
| `camera` | `camera to faro 2` · `camera follow` · `camera shake 0.5` | |
| `fade` | `fade out 1` · `fade in` | dissolvenza al nero |
| `print` | `print monete={monete}` | messaggio di debug |
| `end_game` | `end_game` | fine della partita (torna al menu) |

Esempio completo con quasi tutto:

```
on use leva:
    if state(leva) == "giu":
        nina: È già abbassata.
        stop
    walk to leva
    anim tira
    state leva giu
    camera shake 0.3
    enable ponte
    cutscene:
        camera to ponte 1.5
        wait 1
        narrator: Con un cigolio, il ponte si abbassa.
        camera follow
    set leve_usate += 1
    random:
        nina: Fatto!
        nina: Ecco qua.
        do:
            nina: Uff...
            nina: Era dura.
```

### 8.3 Espressioni

Operatori: `and`, `or`, `not`, `==`, `!=`, `<`, `>`, `<=`, `>=`, `+`, `-`, `*`, `/`, `%`,
`in` (anche `not in`), parentesi, liste `[1, 2]`, testo tra virgolette.

Il linguaggio è tollerante: una variabile mai assegnata vale `null`, che è uguale a
`false`, `0` e `""`; `true == 1`; `"monete: " + 3` fa `"monete: 3"`; `7 / 2` fa `3.5`.
Il controllo (lint) segnala comunque le variabili mai assegnate, perché spesso sono errori
di battitura. Le variabili possono avere punti nel nome (`beppe.arrabbiato`).

Funzioni disponibili:

| Funzione | Risultato |
|---|---|
| `has(oggetto)` · `has(oggetto, personaggio)` | l'oggetto è nell'inventario |
| `visited(stanza)` · `visits(stanza)` | già visitata / quante volte |
| `room()` · `player()` | stanza attuale / protagonista attuale |
| `state(obj)` · `state(obj, stanza)` | stato visivo |
| `shown(obj)` · `enabled(obj)` | visibile / interattivo (anche in altre stanze) |
| `room_of(personaggio)` | dove si trova un personaggio |
| `near(personaggio, bersaglio)` | se è vicino (40 pixel, o un terzo argomento) |
| `used(dialogo.opzione)` | quante volte è stata scelta un'opzione |
| `name(id)` | nome visualizzato di un oggetto, hotspot o personaggio |
| `is_player(personaggio)` | è il protagonista |
| `random(a, b)` · `chance(percentuale)` | numero a caso / vero con quella probabilità |
| `str()` · `int()` · `float()` · `len()` · `min()` · `max()` · `abs()` | utilità |
| `said(testo)` · `ended()` | per i test: è stato detto / la partita è finita |
| qualunque funzione GDScript | della stanza o di `game.gd` (vedi capitolo 12) |

Regola comoda: nelle funzioni che vogliono un **id** (`has`, `visited`, `state`, `shown`,
`enabled`, `room_of`, `used`, `name`, `is_player`, `near`) un nome senza virgolette è l'id
stesso: `has(chiave)` equivale a `has("chiave")`. Negli altri casi il testo va tra
virgolette: `state(barile) == "aperto"`.

Nel testo delle battute le espressioni vanno tra graffe: `nina: Ho {monete} monete.`
(per scrivere una graffa: `\{`).

## 9. Dialoghi

```
dialog beppe:
    on start:                       # eseguito all'apertura (facoltativo)
        once:
            beppe: Ehilà, ragazza!
        beppe: Che ti serve?

    option "Chi sei?" once:          # "once": sparisce dopo essere stata scelta
        beppe: Mi chiamo Beppe.

    option faro "Il faro è spento. Posso aiutarti?":
        beppe: Portami dei vermi.
        option on beppe.vermi        # sblocca un'opzione nascosta

    option vermi "Dove trovo dei vermi?" hidden once:
        beppe: Sotto la sabbia bagnata.

    option "Parliamo d'altro":
        dialog beppe_pettegolezzi    # sotto-dialogo: con "back" si torna qui

    option "Hai visto il tesoro?" if visited(grotta):   # visibile solo se la condizione è vera
        beppe: Quale tesoro?

    option "Ciao, Beppe.":
        beppe: Buona fortuna!
        end                          # chiude tutto il dialogo
```

- Il protagonista **pronuncia** automaticamente il testo dell'opzione scelta; aggiungi
  `silent` all'opzione per evitarlo (o disattiva `avventura/dialog/player_says_options`).
- Un id (come `faro`) serve per riferirsi all'opzione da altri script
  (`option off beppe.faro`, `used(beppe.faro)`); senza id viene ricavato dal testo.
- Dopo una scelta il menu ricompare, finché uno script non fa `end`, un sotto-dialogo fa
  `back`, o non restano opzioni.
- Si avvia un dialogo con `dialog NOME`, di solito da `on talk personaggio:`.

## 10. Interfacce di gioco

Si sceglie dalla scheda Avventura (menu *Interfaccia*) o in *Impostazioni progetto →
avventura/gui/scene*.

**Due clic (predefinita, moderna).** Clic sinistro: cammina o esegue l'azione principale
dell'hotspot (parla con i personaggi, raccoglie gli oggetti, esce dalle uscite...). Clic
destro: guarda. L'inventario sale dal bordo in basso: clic su un oggetto per prenderlo in
mano, poi clic su qualcosa per usarlo; clic destro su un oggetto per guardarlo. Doppio clic
su un'uscita: si esce subito.

**Verbi SCUMM (stile Monkey Island 2).** Nove verbi, la riga della frase ("Usa chiave con
porta") e l'inventario in un pannello in basso. Clic destro esegue il verbo predefinito,
evidenziato nel pannello. Le stanze pensate per questa interfaccia dovrebbero lasciare
libera la fascia bassa (circa 190 pixel), come nei giochi originali; altrimenti la
telecamera scorre sopra il pannello. I verbi sono configurabili nella proprietà `verbs`.

**Stile AGS (barra icone).** Come nei modelli di Adventure Game Studio: portando il mouse in
cima allo schermo compare una barra di icone (inventario, salva, carica, menu); l'inventario è
una finestra con la griglia degli oggetti, i pulsanti "seleziona" e "guarda", le frecce per
scorrere e "Chiudi". Nelle stanze il mouse funziona come nell'interfaccia a due clic; un
oggetto selezionato nella finestra resta in mano e si usa cliccando su qualcosa. Tasto **I**:
apre e chiude l'inventario. Posizioni e immagini vengono da `game/gui/ags_gui.json`, scritto
dall'importatore AGS a partire dalle GUI del gioco originale (si può modificare a mano:
coordinate, immagini, azioni `inventory`/`save`/`load`/`menu`/`quit` della barra e
`select`/`look`/`up`/`down`/`close` della finestra). Senza quel file usa una barra e una
finestra semplici.

Comandi comuni a tutte le interfacce:

| Tasto | Azione |
|---|---|
| clic / Spazio / . | salta la battuta |
| Esc | salta la cutscene, posa l'oggetto in mano, apre il menu di pausa |
| Tab (tenuto premuto) | mostra i nomi di tutti gli hotspot |
| 1–9 | sceglie un'opzione di dialogo |
| F5 / F9 | salvataggio / caricamento rapido |
| \ (tasto a sinistra dell'1) o F12 | console di debug (solo nelle build di debug) |

**Personalizzare.** Le proprietà esportate delle scene `two_click_gui.tscn` e
`scumm_gui.tscn` (dimensioni dei caratteri, colori, verbi) si cambiano dall'ispettore;
`gui_theme` accetta un tema Godot. Per un'interfaccia tutta nuova (per esempio una "verb
coin") estendi `AdvGui` e ridefinisci `click_world()`, `click_item()` e `hover_text()`, poi
indica la tua scena nelle impostazioni.

Il menu iniziale mostra `game/title.svg|png` se esiste. Il giocatore può regolare velocità
del testo, avanzamento automatico, volumi e schermo intero (salvati in `user://settings.cfg`).

## 11. Salvataggi

Il menu di pausa offre sei posizioni di salvataggio più il salvataggio rapido. Si può
salvare quando il gioco aspetta il giocatore (non durante script o cutscene). Il file è
JSON leggibile in `user://saves/` e contiene variabili, inventari, stanza, posizioni dei
personaggi, stati degli oggetti, opzioni dei dialoghi e contatori (`times`, `cycle`...).
Dopo un caricamento viene eseguito `on setup` della stanza, non `on enter`.

## 12. GDScript: quando serve più potenza

AdvScript copre la maggior parte dei casi; per il resto c'è GDScript.

**Funzioni della stanza.** Assegna alla radice della stanza uno script che estende
`AdvRoom`; le sue funzioni si chiamano da AdvScript:

```gdscript
extends AdvRoom

func apri_botola() -> void:          # call apri_botola()
	$Botola/AnimationPlayer.play("apri")
	await $Botola/AnimationPlayer.animation_finished

func combinazione_giusta(n) -> bool:  # if combinazione_giusta(codice):
	return n == 1234
```

**Funzioni globali.** Lo stesso vale per `game/game.gd` (estende `Node`), creato all'avvio.

**Il motore da GDScript.** L'autoload `Adv` offre gli stessi comandi degli script:

```gdscript
await Adv.say("nina", "Ciao!")
await Adv.walk("nina", "porta")          # o una posizione Vector2
Adv.face("nina", "left")
await Adv.anim("beppe", "balla")
Adv.inventory_add("chiave")
Adv.has_item("chiave")
Adv.set_var("monete", 3); Adv.get_var("monete")
Adv.set_object_state("porta", "aperta")
Adv.set_object_visible("buca", true)
await Adv.change_room("faro", "ingresso")
Adv.perform("use", "porta", "chiave")      # come un clic del giocatore
await Adv.interp.run_source("nina: Posso eseguire AdvScript!")
Adv.save_game("slot1"); await Adv.load_game("slot1")
```

Segnali utili: `room_entered`, `speech_started`, `speech_finished`, `choice_requested`,
`inventory_changed`, `item_selected`, `cutscene_changed`, `game_started`, `game_ended`,
`transcript_line` (tutto ciò che accade, in testo). `Adv.state.custom` è un dizionario
libero che viene salvato con la partita.

## 13. Test, console e strumenti

### Il linguaggio dei comandi

Console di debug, test automatici, controllo remoto e Claude Code usano lo stesso
linguaggio, che somiglia al gioco stesso:

```
look cartello              talk to beppe            use chiave on porta
pick pala                  give vermi to beppe      walk verso_molo     walk 400 600
choose 2                   choose "Chi sei"         skip
scene                      state     inv     vars     get monete     eval has(chiave)
expect has(chiave)         expect room() == "faro"  expect said("Beppe")
goto faro                  item add chiave          set monete = 10
run nina: Posso dire quello che voglio\ndialog beppe
new     save prova     load prova     reload     fast on|off     screenshot     lint
click 400 600     rclick 400 600     gui show_pause     gui show_settings     gui close
```

`scene` elenca gli hotspot della stanza con id, nome, verbo principale e uscite: è il modo
più rapido per orientarsi. `reload` ricarica gli script `.adv` senza riavviare il gioco.
Aggiungendo ` &` in fondo a un comando non se ne aspetta la fine.

### Test automatici (`.advtest`)

Un file `.advtest` è una partita scritta: una riga per comando, più le verifiche `expect`.
Ogni file parte da una nuova partita in modalità istantanea (niente attese). Esempio:

```
look cartello
expect said("Beppe")
pick pala
expect has(pala)
use pala on sabbia
expect has(vermi)
```

Tieni sempre aggiornata la soluzione completa (`game/tests/walkthrough.advtest`): ti dirà
subito se una modifica rende il gioco impossibile da finire. Puoi anche **registrare** una
partita giocata a mano: avvia il gioco con `-- --adv-record=res://game/tests/nuovo.advtest`
(oppure `record percorso` dalla console) e aggiungi poi le righe `expect`.

### Controllo (lint)

Trova errori di sintassi, stanze/hotspot/oggetti/personaggi/dialoghi inesistenti (con
suggerimenti "intendevi...?"), punti d'ingresso mancanti, uscite verso stanze che non ci
sono, variabili mai assegnate, opzioni nascoste mai sbloccate, hotspot senza risposte.

### Da terminale

```sh
python3 tools/adv.py lint
python3 tools/adv.py test
python3 tools/adv.py play "look cartello; pick pala" --new    # lo stato resta tra un comando e l'altro
python3 tools/adv.py shot schermata.png
python3 tools/adv.py run          # avvia il gioco con il controllo remoto attivo
python3 tools/adv.py live "scene" # comanda il gioco avviato
python3 tools/adv.py new-room grotta "La grotta"
```

Serve Python 3.8+; se `godot` non è nel PATH imposta la variabile d'ambiente `GODOT`.
Gli stessi strumenti sono disponibili direttamente da Godot con gli argomenti dopo `--`:
`--adv-lint`, `--adv-test`, `--adv-run="comandi"`, `--adv-remote=7777`, `--adv-start=stanza`,
`--adv-gui=scumm`, `--adv-fast`, `--adv-load`/`--adv-save`, `--adv-screenshot`,
`--adv-record`, `--adv-seed`, `--adv-game-dir`.

### Controllo remoto

Con `--adv-remote[=porta]` (o *avventura/debug/remote_control* nelle build di debug) il gioco
accetta comandi via TCP su `127.0.0.1`, una riga JSON per comando
(`{"id": 1, "cmd": "look cartello"}`) con risposta `{"id", "ok", "output", "status"}`.

## 14. Lavorare con Claude Code

Il progetto è pronto per Claude Code:

- **`CLAUDE.md`** spiega a Claude struttura, convenzioni e linguaggio.
- **Server MCP** (`.mcp.json`, file `tools/adv_mcp.py`, nessuna dipendenza): Claude può
  controllare (`adventure_lint`), testare (`adventure_test`), **giocare** in una sessione che
  ricorda lo stato (`adventure_play`), **vedere** il gioco (`adventure_screenshot`), creare
  stanze/personaggi/oggetti (`adventure_create`) e perfino comandare la finestra in cui stai
  giocando tu (`adventure_live`, dopo `python3 tools/adv.py run`).
  Alla prima apertura Claude Code chiede di approvare il server del progetto.
- **Skill** in `.claude/skills/`: `playtest` (prova il gioco come un giocatore e fa un
  rapporto), `new-room` (crea una stanza completa), `new-puzzle` (progetta e implementa un
  enigma con il suo test).

Richieste tipiche: *"aggiungi una grotta raggiungibile dalla spiaggia con un enigma sulla
marea"*, *"fai un playtest e dimmi dove un giocatore si blocca"*, *"rendi più vari i
commenti di Nina quando un'azione non funziona"*. Claude modifica script e scene, poi
verifica con lint, test, una partita e uno screenshot.

## 15. Impostazioni del progetto

| Impostazione | Predefinito | Significato |
|---|---|---|
| `avventura/general/game_dir` | `res://game` | cartella del gioco |
| `avventura/gui/scene` | `two_click_gui.tscn` | interfaccia |
| `avventura/gui/show_title_menu` | `true` | menu iniziale |
| `avventura/gui/language` | `""` | lingua dell'interfaccia (`it`, `en`; vuoto = del sistema) |
| `avventura/text/seconds_per_character` | `0.05` | durata delle battute |
| `avventura/text/min_seconds` | `1.5` | durata minima di una battuta |
| `avventura/interaction/walk_before_look` | `false` | camminare fino alle cose prima di guardarle |
| `avventura/dialog/player_says_options` | `true` | il protagonista pronuncia l'opzione scelta |
| `avventura/debug/remote_control` | `false` | controllo remoto nelle build di debug |
| `avventura/debug/remote_port` | `7777` | porta del controllo remoto |
| `avventura/debug/console` | `true` | console di debug |
| `avventura/debug/show_walk_areas` | `false` | mostra le aree calpestabili durante il gioco |

## 16. Esportare e tradurre

**Esportazione.** Usa il normale *Progetto → Esporta* di Godot. Il plugin aggiunge da solo i
file `.adv` al pacchetto. Le cartelle `tests/` e `tools/` non servono al gioco: puoi
escluderle nei filtri dell'esportazione.

**Traduzioni.** Tutto il testo mostrato passa da `tr()`: con i normali file di traduzione di
Godot (CSV o PO) puoi tradurre battute, nomi e opzioni usando il testo originale come
chiave. Le scritte dell'interfaccia sono già in inglese e italiano
(`addons/avventura/i18n/avventura.csv`); aggiungi una colonna per altre lingue.

## 17. Importare un gioco AGS

`tools/ags/` converte giochi fatti con Adventure Game Studio 3.x (formati 3.0–3.6). Il modo
più semplice è importare l'intera cartella del progetto AGS in un progetto Godot nuovo
(con dentro `addons/avventura` e `tools`):

```sh
python3 tools/ags/ags_import.py game PERCORSO/CARTELLA_AGS
```

Dalla cartella vengono letti:

- `Game.agf`: titolo, risoluzione (impostata anche in `project.godot`), personaggi con
  colore del testo, stanza e posizione iniziale, oggetti dell'inventario, variabili globali;
- `acsprset.spr`: gli sprite. Ogni personaggio diventa una scena
  `game/characters/<id>/<id>.tscn` con le animazioni prese dalle sue *view* (`walk_*` e
  `idle_*` dalla view normale, `talk_*` da quella del parlato, le altre view usate da
  `LockView` con il loro nome, es. `climb_down`); le icone vanno in `game/items/`;
- le GUI che sono solo immagini (es. una schermata a tutto schermo) diventano *overlay* in
  `game/overlays/<id>.tscn`, da mostrare con `show id` / `hide id`; la barra delle icone e la
  finestra dell'inventario diventano l'interfaccia **Stile AGS** (`game/gui/ags_gui.json`,
  capitolo 10); gli altri pannelli (salvataggi, opzioni) usano i menu del motore;
- tutte le `roomN.crm` / `roomN.asc`, lo script globale, i video `.ogv`/`.webm` (in
  `game/video/`) e l'audio, se i file sono nella cartella (altrimenti l'elenco finale dice
  quali file copiare in `game/audio/` e con che nome).

Si possono anche importare pezzi singoli:

```sh
# una stanza: sfondo, aree calpestabili (con i buchi), hotspot, regioni, walk-behind, oggetti, script
python3 tools/ags/ags_import.py room PERCORSO/room1.crm --asc PERCORSO/room1.asc --player cRay
# lo script globale (gestori di personaggi e oggetti, funzioni)
python3 tools/ags/ags_import.py script PERCORSO/GlobalScript.asc --player cRay
# solo l'interfaccia (barra icone + finestra dell'inventario), senza toccare stanze e script
python3 tools/ags/ags_import.py gui PERCORSO/CARTELLA_AGS
# solo gli sprite, come PNG
python3 tools/ags/spr.py PERCORSO/acsprset.spr --out cartella/ [--only 26,37]
```

`--player` è il nome script del protagonista AGS. Le maschere diventano poligoni, le
walk-behind diventano sprite ritagliati dallo sfondo e ordinati alla loro *baseline*, i
bordi della stanza con un evento diventano regioni `edge_left`, `edge_right`... Il codice
viene tradotto in AdvScript: `Say`, `SayAt` (`john@476,172: testo`), `Walk` (anche relativo
e `eAnywhere`), inventario, `ChangeRoom`, `SetAsPlayer`, dialoghi, cutscene, `Wait`,
`LockView`, `PlayVideo`, musica e suoni, GUI mostrate/nascoste, il modulo *Verbs* a 9 verbi
(`AnyClick`, `UsedAction`, `MovePlayer`), `ActiveInventory`, `Game.DoOnceOnly`... Ciò che
non sa tradurre resta nel file come `# TODO AGS:` con il codice originale; lo script
originale viene copiato in `rooms/<id>/ags/`. Il controllo (lint) elenca poi i riferimenti
ancora da sistemare. Non ancora importati: il testo dei dialoghi di `Game.agf`, i font e i
moduli di script aggiuntivi.
