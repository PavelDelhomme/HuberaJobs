# Contrôleur d’émulateur Android

À lancer **sur la machine hôte** où Android SDK et Flutter sont installés. Le backoffice (Émulateur mobile) s’y connecte pour lister les AVD, les appareils ADB, démarrer un émulateur, builder l’APK et afficher l’écran réel (screenshot).

## Prérequis

- Node.js (v16+)
- Android SDK (`emulator`, `adb` dans le PATH ou `ANDROID_HOME` défini)
- Flutter dans le PATH

## Lancement

**Démarrage automatique** : le contrôleur est lancé automatiquement à la fin de **`make up-full`** (si Node et `tools/emulator-controller/server.js` sont présents). Aucun 2e terminal nécessaire.

**Lancement manuel** (si besoin) :
```bash
make emulator-controller
```
Ou en arrière-plan : `make emulator-controller-bg` (arrêt : `make emulator-controller-stop`).

Écoute par défaut sur **http://0.0.0.0:5055**. Ouvrez Backoffice → Émulateur mobile pour le rendu en direct (AVD ou téléphone connecté en USB).

## Variables d’environnement

| Variable | Description |
|----------|-------------|
| `EMULATOR_CONTROLLER_PORT` | Port (défaut : 5055) |
| `EMULATOR_CONTROLLER_BASE_PATH` | Préfixe d’URL (ex. `/emulator-api`) quand le service est derrière un reverse proxy |
| `MOBILE_PROJECT_PATH` | Chemin du projet Flutter mobile (défaut : `../../mobile`) |
| `ANDROID_HOME` ou `ANDROID_SDK_ROOT` | Racine du SDK Android |
| `ANDROID_PACKAGE` | Package Android de l’app pour « Installer et lancer » (défaut : cloud.hubera.jobs) |

## Dépannage Build APK

- **NoSuchFileException kotlin-compiler-*.salive** (Flutter SDK en lecture seule, ex. `/usr/lib/flutter`) : le contrôleur copie automatiquement `packages/flutter_tools/gradle` dans `mobile/.flutter-gradle-cache` et utilise cette copie pour le build. La première fois, la copie peut prendre quelques secondes. Si la copie échoue (droits), exécuter une fois sur la machine : `sudo chown -R $USER:$USER /usr/lib/flutter` ou créer un groupe dédié (voir [Stack Overflow](https://stackoverflow.com/questions/79507549)).
- **file_picker (linux/macos/windows)** : avertissements du plugin, en général non bloquants.

## Depuis Docker (backoffice dans un conteneur)

Depuis le backoffice, utilisez l’URL du host, par exemple : **http://host.docker.internal:5055** (ou l’IP de votre machine sur le réseau local).

## Endpoints

- `GET /health` – Santé du service
- `GET /avds` – Liste des AVD (images Android, plusieurs niveaux API)
- `GET /devices` – Liste des appareils ADB (émulateurs + physiques)
- `GET /flutter-devices` – Liste des appareils vus par Flutter (pour « Flutter run »)
- `POST /start-avd` – Body `{ "avd": "nom_avd" }` – Démarre un AVD
- `POST /build-apk` – Build `flutter build apk --debug` dans le projet mobile
- `POST /install-run` – Body `{ "deviceId": "emulator-5554" }` – Installe l’APK et lance l’app
- `POST /run-flutter` – Body `{ "deviceId": "emulator-5554" }` – `flutter run -d deviceId`
- `GET /screenshot?device=emulator-5554` – Capture d’écran PNG de l’appareil
- `POST /tap-field-and-type` – Body `{ "deviceId", "hint", "text", "index" }` – Tap sur un champ (hint/text), vide, puis saisie. Pour l’email (formulaire inscription), un seul `input text` est utilisé ; si le clavier de l’appareil corrompt la saisie (ex. "6" en trop), essayer un autre clavier dans les paramètres Android ou valider le flux via l’API : `cd tests && npm run test:inscription-gmail`.
