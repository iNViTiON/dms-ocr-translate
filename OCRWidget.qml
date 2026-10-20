import QtQuick
import QtQuick.Controls
import Quickshell.Io
import qs.Common
import qs.Services
import qs.Widgets
import qs.Modules.Plugins
import qs.Modals.FileBrowser
import "./shared"
import "./Translator.js" as Translator

PluginComponent {
    id: pluginRoot

    popoutWidth: 1180
    // Room for the scanner, the three columns and the buttons under them; the content scrolls if the screen is smaller.
    popoutHeight: (pluginData.showHints ?? true) ? 720 : 640
    // The picture/text boxes: shorter while the language picker is open, so the buttons under them stay in view;
    // the translation alone gets most of the window when it is maximized.
    property bool outputMaximized: false
    readonly property int boxHeight: outputMaximized ? popoutHeight - 340 : (langExpanded ? 150 : 260)

    // Closing the window folds the extras back up.
    function resetWindowState() {
        langExpanded = false;
        outputMaximized = false;
    }

    pillRightClickAction: () => {
        const showPopout = pluginData.showPopoutOnRightClick ?? true;
        if (showPopout) pluginRoot.triggerPopout();
        pluginRoot.scanFromClipboard();
    }

    property string resultText: ""
    property bool isScanning: false
    property bool isSaving: false
    property bool isAutoScanning: false
    property string sourceImage: ""
    property int imageTrigger: 0
    property int lastScanTime: 0

    // Upstream computes this with StandardPaths, but never imports QtCore, so it threw and
    // the folder stayed "". A fixed folder works (it is also created at login by the config).
    readonly property string cacheDir: Paths.expandTilde("~/.cache/dms-ocr")

    // Translation (see Translator.js). Settings come from OCRSettings.qml.
    property string scanError: ""


    // Recognition languages for this session only. null = the default list from the settings.
    // Nothing is saved, so a restart (or the Reset button) goes back to the default.
    property var sessionLangs: null
    property var installedOcrLangs: []
    property bool langExpanded: false
    property string lastScanLang: ""
    readonly property string defaultOcrLanguage: pluginData.ocrLanguage || "eng"
    readonly property string effectiveOcrLanguage: sessionLangs !== null && sessionLangs.length > 0
        ? sessionLangs.join("+") : defaultOcrLanguage
    readonly property var selectedOcrLangs: effectiveOcrLanguage.split("+").filter(l => l !== "")
    readonly property bool langsChanged: effectiveOcrLanguage !== defaultOcrLanguage

    function toggleSessionLang(lang) {
        const list = selectedOcrLangs.slice();
        const at = list.indexOf(lang);
        if (at >= 0) {
            if (list.length === 1) return;
            list.splice(at, 1);
        } else {
            list.push(lang);
        }
        sessionLangs = list;
    }
    // Seconds since the scan started. Tesseract's command line reports no progress, so this is all there is to show.
    property int scanSeconds: 0
    onIsScanningChanged: scanSeconds = 0

    Timer {
        interval: 1000
        repeat: true
        running: pluginRoot.isScanning
        onTriggered: pluginRoot.scanSeconds++
    }
    property string translatedText: ""
    property bool isTranslating: false
    property string translateError: ""
    property string translateInfo: ""
    // Long text is translated in pieces (Translator.translateLong): "Part 3 of 9".
    property string translateProgress: ""
    property int translateSeconds: 0
    onIsTranslatingChanged: translateSeconds = 0

    Timer {
        interval: 1000
        repeat: true
        running: pluginRoot.isTranslating
        onTriggered: pluginRoot.translateSeconds++
    }
    property var translateRequest: null
    readonly property string serverUrl: pluginData.serverUrl || Translator.DEFAULT_URL
    readonly property string modelName: pluginData.model || Translator.DEFAULT_MODEL
    readonly property string promptTemplate: pluginData.prompt || Translator.DEFAULT_PROMPT
    readonly property bool translateAfterScan: pluginData.translateAfterScan ?? true
    readonly property string copyWhich: pluginData.copyWhich || "translation"
    // "" = take the source language from the OCR language.
    readonly property string fromCode: pluginData.sourceLang || ""
    readonly property string toCode: pluginData.targetLang || "en"
    readonly property bool translateOnEdit: pluginData.translateOnEdit ?? true
    // Input the shown translation belongs to (languages + text), so an unchanged input isn't sent again.
    property string lastTranslateKey: ""
    property int translateSeq: 0
    readonly property string autoFromLabel: "Auto (from OCR language)"
    readonly property var fromOptions: [autoFromLabel].concat(Translator.LANGUAGES.map(l => Translator.languageLabel(l)))
    readonly property var toOptions: Translator.LANGUAGES.map(l => Translator.languageLabel(l))
    readonly property string saveFileName: savingTranslation ? "ocr_translation.txt" : "ocr_result.txt"
    property bool savingTranslation: false
    property string saveContent: ""

    // "Auto": a script that belongs to one language (Thai, Japanese, ...) is recognised from the text; for
    // Latin text, which could be any language, the first recognition language is the best guess.
    function sourceCode() {
        if (fromCode !== "") return fromCode;
        const detected = Translator.detectSourceCode(resultText);
        return detected !== "" ? detected : Translator.sourceFromOcr(effectiveOcrLanguage);
    }

    function sourceLanguage() {
        return Translator.languageByCode(sourceCode());
    }

    function translateKey(from, to, text) {
        return from + "|" + to + "|" + text.trim();
    }

    function setLanguage(key, label, auto) {
        const language = auto ? undefined : Translator.languageByLabel(label);
        pluginService.savePluginData(pluginRoot.pluginId, key, language ? language.code : "");
        translatedText = "";
        lastTranslateKey = "";
        // The new language is read from the saved settings, so translate a moment later.
        if (resultText.trim() !== "") languageTimer.restart();
    }

    // Translator mode: the translation becomes the input and the other way round, with the
    // languages swapped. Nothing is sent: the pair already belongs together.
    function swapLanguagesAndText() {
        const from = sourceCode();
        const to = toCode;
        if (from === "") {
            translateError = "Pick the source language first: it can't be read from the OCR language.";
            return;
        }
        cancelTranslation();
        const input = resultText;
        resultText = translatedText;
        translatedText = input;
        pluginService.savePluginData(pluginRoot.pluginId, "sourceLang", to);
        pluginService.savePluginData(pluginRoot.pluginId, "targetLang", from);
        lastTranslateKey = translateKey(to, from, resultText);
        translateError = "";
        translateInfo = "";
    }

    Timer {
        id: editTimer
        interval: 1200
        repeat: false
        onTriggered: if (pluginRoot.translateOnEdit) pluginRoot.translateNow(false, true)
    }

    Timer {
        id: languageTimer
        interval: 150
        repeat: false
        onTriggered: pluginRoot.translateNow(false, false)
    }

    // Scan the current image again, e.g. after editing the text by hand.
    // Tesseract is running (as opposed to waiting for a screenshot or the clipboard).
    property bool ocrRunning: false
    property int scanSeq: 0
    property string ocrPidFile: ""
    property var ocrCleanup: []

    // Stop the Tesseract run that is going, e.g. because the languages changed and it is scanned again.
    function stopOcr() {
        if (!ocrRunning || ocrPidFile === "") return;
        Proc.runCommand("ocr-stop-" + scanSeq,
            ["sh", "-c", 'p=$(cat "$1" 2>/dev/null); [ -n "$p" ] && { pkill -P "$p"; kill "$p"; }; rm -f "$1"', "sh", ocrPidFile], null, 0);
    }

    // Re-scan also works while a scan is running: the running one is stopped and its result dropped.
    function rescan() {
        if (sourceImage === "" || (isScanning && !ocrRunning)) return;
        const cleanup = ocrRunning ? ocrCleanup : [];
        stopOcr();
        isScanning = true;
        scanSeconds = 0;
        runTesseract(sourceImage, true, cleanup);
    }

    // Stop the translation that is running: the request is aborted (the server stops generating when the
    // connection closes) and its answer is ignored. A newer translation always calls this first, so they
    // never queue up.
    function cancelTranslation() {
        if (translateRequest) translateRequest.abort();
        translateRequest = null;
        translateSeq++;
        isTranslating = false;
        translateProgress = "";
    }

    // The Stop button: everything that is going on, scan and translation, plus what is waiting to start.
    function stopAll() {
        editTimer.stop();
        languageTimer.stop();
        captureTimer.stop();
        const wasBusy = isScanning || isTranslating;
        cancelTranslation();
        if (ocrRunning) {
            stopOcr();
            if (ocrCleanup.length > 0) Proc.runCommand("ocr-cleanup", ["rm", "-f"].concat(ocrCleanup), null, 0);
            scanSeq++; // the stopped run's answer is dropped
            ocrRunning = false;
        }
        if (capturing) {
            capturing = false; // the region picker's answer is dropped
            Proc.runCommand("ocr-stop-capture", ["pkill", "-f", "dms screenshot region"], null, 0);
        }
        isScanning = false;
        isAutoScanning = false;
        translateError = "";
        if (wasBusy) {
            translateInfo = "Stopped";
            ToastService.showInfo("Stopped.");
        }
    }

    function translateNow(automatic, onlyIfChanged) {
        if (resultText.trim() === "") {
            // Nothing left to translate: stop a translation of the old text and drop its output.
            cancelTranslation();
            translatedText = "";
            lastTranslateKey = "";
            return;
        }
        const source = sourceLanguage();
        const target = Translator.languageByCode(toCode);
        if (!source) {
            translateError = "Pick the source language: it can't be read from the OCR language.";
            return;
        }
        if (!target) {
            translateError = "Pick a target language.";
            return;
        }
        if (source.code === target.code) {
            translateError = "From and To are both " + Translator.languageLabel(source) + ". Pick the language the text is written in.";
            return;
        }
        const key = translateKey(source.code, target.code, resultText);
        if (onlyIfChanged && key === lastTranslateKey && translatedText !== "") return;
        // A newer request replaces one still running: stop that first, its answer is ignored.
        cancelTranslation();
        const seq = translateSeq;
        isTranslating = true;
        translateError = "";
        translateInfo = "";
        translateProgress = "";
        translateRequest = Translator.translateLong({
            serverUrl: serverUrl,
            model: modelName,
            template: promptTemplate,
            source: source,
            target: target,
            text: resultText.trim()
        }, (done, total, partial) => {
            if (seq !== translateSeq) return;
            if (total > 1) translateProgress = "Part " + Math.min(done + 1, total) + " of " + total;
            // Show what is translated so far while the rest is going.
            if (partial !== "") translatedText = partial;
        }, (error, result) => {
            if (seq !== translateSeq) return;
            isTranslating = false;
            translateRequest = null;
            if (error) {
                translateError = error;
                return;
            }
            translatedText = result.text;
            lastTranslateKey = key;
            translateProgress = "";
            translateInfo = (result.parts > 1 ? result.parts + " parts · " : "") + modelName + (result.cached ? " · cached"
                : result.tokensPerSecond ? " · " + result.tokensPerSecond.toFixed(1) + " tok/s" : "");
            if (automatic && result.text !== "" && (pluginData.autoCopy ?? true) && copyWhich === "translation")
                copyToClipboard(result.text);
        });
    }

    Component.onCompleted: {
        Proc.runCommand("ocr-init-dir", ["mkdir", "-p", cacheDir], null, 0);
        Proc.runCommand("ocr-list-langs", ["tesseract", "--list-langs"], (stdout, exitCode) => {
            if (exitCode !== 0) return;
            // First line is a header; osd is Tesseract's orientation data, not a language.
            installedOcrLangs = stdout.split("\n").slice(1).map(l => l.trim()).filter(l => l !== "" && l !== "osd").sort();
        }, 0);
    }

    function scanFromClipboard() {
        if (isScanning || isAutoScanning) return;
        
        const now = Date.now();
        if (now - lastScanTime < 2000) return;
        lastScanTime = now;

        scanError = "";
        const tempImage = cacheDir + "/dms_ocr_input.png";
        const getClipCmd = "mkdir -p '" + cacheDir + "' && wl-paste -t image/png > '" + tempImage + "' 2>/dev/null";

        Proc.runCommand(
            "get-clipboard-image",
            ["sh", "-c", getClipCmd],
            (stdout, exitCode) => {
                if (exitCode === 0) {
                    Proc.runCommand(
                        "check-image-type",
                        ["file", "--mime-type", "-b", tempImage],
                        (checkOut, checkCode) => {
                            if (checkCode === 0 && checkOut.trim().startsWith("image/")) {
                                isScanning = true;
                                isAutoScanning = true;
                                runTesseract(tempImage, true);
                            } else {
                                scanError = "The clipboard has no image. Copy an image first (a screenshot, or Copy Image in a browser).";
                                ToastService.showError(scanError);
                            }
                        },
                        0
                    );
                } else {
                    scanError = "Couldn't read the clipboard: is wl-clipboard installed, and does the clipboard hold an image?";
                    ToastService.showError(scanError);
                }
            },
            0
        );
    }

    // The window takes a moment to disappear; capturing at once photographs part of it.
    readonly property int captureDelayMs: 100

    Timer {
        id: captureTimer
        interval: pluginRoot.captureDelayMs
        repeat: false
        onTriggered: pluginRoot.scanFromScreenshot(true)
    }

    // Commands for key bindings, e.g. in niri:
    //   Mod+Shift+S { spawn "dms" "ipc" "call" "ocrTranslate" "capture"; }
    // capture: pick a screen region, scan it and show the window (like the Capture button);
    // clipboard: scan the clipboard image; toggle: open or close the window.
    IpcHandler {
        target: "ocrTranslate"

        function capture(): string {
            if (pluginRoot.isScanning) return "busy";
            pluginRoot.closePopout();
            captureTimer.restart();
            return "ok";
        }

        function clipboard(): string {
            if (pluginRoot.isScanning) return "busy";
            pluginRoot.triggerPopout();
            pluginRoot.scanFromClipboard();
            return "ok";
        }

        function toggle(): string {
            pluginRoot.triggerPopout();
            return "ok";
        }
    }

    // fromPopout: the button in the window closes it so the region can be picked, and it comes back with the result.
    property bool capturing: false

    function scanFromScreenshot(fromPopout) {
        isScanning = true;
        capturing = true;
        scanError = "";
        const tempPath = cacheDir + "/dms_ocr_screenshot.png";

        Proc.runCommand(
            "screenshot-ocr",
            ["dms", "screenshot", "region", "--no-confirm", "--no-notify", "--dir", cacheDir, "--filename", "dms_ocr_screenshot.png"],
            (stdout, exitCode) => {
                if (!capturing) return; // stopped meanwhile
                capturing = false;
                if (exitCode === 0) {
                    sourceImage = tempPath;
                    imageTrigger++;
                    runTesseract(tempPath);
                    pluginRoot.triggerPopout();
                } else {
                    isScanning = false;
                    scanError = exitCode === 124 ? "No region selected within 2 minutes."
                        : "No screenshot taken: the selection was cancelled, or `dms screenshot` failed (exit code " + exitCode + ").";
                    ToastService.showError(scanError);
                    if (fromPopout === true) pluginRoot.triggerPopout();
                }
            },
            0,
            120000 // the region selector waits for you; the default limit is 10 s
        );
    }

    function selectFileAndScan() {
        pluginRoot.closePopout();
        fileBrowserModal.open();
    }

    function scanFromUrl(url) {
        if (!url || isScanning) return;
        
        const convertSvgToPng = function(inputPath, callback, cleanupInput) {
            const outputPath = cacheDir + "/dms_ocr_svg_" + Date.now() + ".png";
            Proc.runCommand(
                "svg-convert",
                ["rsvg-convert", "-w", "2000", "-h", "2000", "-f", "png", "-o", outputPath, inputPath],
                (stdout, exitCode) => {
                    if (exitCode === 0) {
                        callback(outputPath, cleanupInput ? [inputPath, outputPath] : [outputPath]);
                    } else {
                        Proc.runCommand(
                            "svg-convert-fallback",
                            ["convert", "-background", "white", "-alpha", "remove", inputPath, outputPath],
                            (stdout2, exitCode2) => {
                                if (exitCode2 === 0) {
                                    callback(outputPath, cleanupInput ? [inputPath, outputPath] : [outputPath]);
                                } else {
                                    if (cleanupInput) Proc.runCommand("ocr-clean", ["rm", "-f", inputPath], null, 0);
                                    callback(null, []);
                                }
                            },
                            0
                        );
                    }
                },
                0
            );
        };

        const processImage = function(path, isTemp) {
            if (path.toLowerCase().endsWith(".svg")) {
                convertSvgToPng(path, function(convertedPath, toClean) {
                    if (convertedPath) {
                        sourceImage = convertedPath;
                        imageTrigger++;
                        isScanning = true;
                        runTesseract(convertedPath, false, toClean);
                    } else {
                        ToastService.showError("Failed to convert SVG to PNG. Install rsvg-convert or imagemagick.");
                    }
                }, isTemp);
            } else {
                sourceImage = path;
                imageTrigger++;
                isScanning = true;
                runTesseract(path, false, isTemp ? [path] : []);
            }
        };

        if (url.startsWith("file://")) {
            processImage(url.substring(7), false);
        } else if (url.startsWith("http://") || url.startsWith("https://")) {
            const tempFile = cacheDir + "/dms_ocr_dl_" + Date.now();
            Proc.runCommand("download-image", ["dms", "dl", url, "-o", tempFile], (stdout, exitCode) => {
                if (exitCode === 0) {
                    processImage(tempFile, true);
                } else {
                    ToastService.showError("Failed to download image from URL.");
                }
            });
        } else if (url.startsWith("/")) {
            processImage(url, false);
        } else {
            ToastService.showError("Invalid image source.");
        }
    }

    // DMS kills a command after 10 s by default (exit code 124). Tesseract needs 10-30 s with a dozen
    // languages selected, and that showed up as "Tesseract failed".
    readonly property int tesseractTimeoutMs: 180000
    readonly property string textMarker: "@@OCR-TEXT@@"

    // DMS gives a command's stdout and exit code only, so this prints Tesseract's stderr first, then
    // the marker, then the recognized text.
    // $3 is a file that gets this shell's pid, so a scan that is replaced can be stopped (stopOcr).
    readonly property string tesseractScript:
        'out=$(mktemp) && err=$(mktemp) || exit 1; ' +
        'cleanup() { rm -f "$out" "$err" "$3"; }; trap cleanup EXIT; echo $$ > "$3"; ' +
        'tesseract "$1" - -l "$2" >"$out" 2>"$err"; rc=$?; ' +
        'cat "$err"; printf "\\n' + textMarker + '\\n"; cat "$out"; exit "$rc"'

    // What went wrong, in words the user can act on.
    function describeTesseractError(exitCode, err, lang) {
        const count = lang.split("+").length;
        const missing = [];
        const re = /Failed loading language '([^']+)'/g;
        let m;
        while ((m = re.exec(err)) !== null) missing.push(m[1]);
        if (exitCode === 124)
            return "Tesseract took longer than " + (tesseractTimeoutMs / 1000) + " s with " + count + " language" + (count === 1 ? "" : "s")
                + " selected. Select fewer recognition languages in the settings.";
        if (missing.length > 0)
            return "Language pack" + (missing.length === 1 ? " " : "s ") + missing.join(", ") + " not installed. Pick other languages in the settings.";
        if (exitCode === 127 || /tesseract: (command )?not found/.test(err))
            return "Tesseract isn't installed.";
        if (/cannot be read|cannot read input file|pixRead|Unsupported image|Invalid/i.test(err))
            return "Couldn't read the image: the file is missing or isn't a supported image.";
        const lines = err.split("\n").map(l => l.trim()).filter(l => l !== "");
        return "Tesseract failed (exit code " + exitCode + ")" + (lines.length > 0 ? ": " + lines[lines.length - 1] : ".");
    }

    function runTesseract(imagePath, skipAutoCopy, cleanupFiles) {
        if (imagePath.includes("dms_ocr_input.png")) {
            sourceImage = imagePath;
            imageTrigger++;
        }
        scanError = "";

        const lang = effectiveOcrLanguage;
        lastScanLang = lang;
        const seq = ++scanSeq;
        const pidFile = cacheDir + "/tesseract-" + seq + ".pid";
        ocrPidFile = pidFile;
        ocrCleanup = cleanupFiles || [];
        ocrRunning = true;

        Proc.runCommand(
            "run-tesseract-" + seq,
            ["sh", "-c", tesseractScript, "sh", imagePath, lang, pidFile],
            (stdout, exitCode) => {
                // A newer scan replaced this one: its files and result are the newer scan's business.
                if (seq !== scanSeq) return;
                ocrRunning = false;
                isScanning = false;
                isAutoScanning = false;
                if (Array.isArray(cleanupFiles) && cleanupFiles.length > 0) {
                    Proc.runCommand("ocr-cleanup", ["rm", "-f"].concat(cleanupFiles), null, 0);
                }
                const cut = stdout.indexOf("\n" + textMarker + "\n");
                const err = cut < 0 ? stdout : stdout.substring(0, cut);
                const result = cut < 0 ? "" : stdout.substring(cut + textMarker.length + 2).trim();
                if (exitCode === 0) {
                    // Tesseract scans with the languages it could load; tell about the others.
                    const skipped = [];
                    const re = /Failed loading language '([^']+)'/g;
                    let m;
                    while ((m = re.exec(err)) !== null) skipped.push(m[1]);
                    if (skipped.length > 0) {
                        const note = "Scanned without " + skipped.join(", ") + ": language pack not installed.";
                        scanError = note;
                        ToastService.showWarning(note);
                    }
                    const text = (pluginData.fixThaiSpacing ?? true) ? Translator.fixThaiSpacing(result) : result;
                    if (text === "") {
                        ToastService.showInfo("No text detected.");
                    } else {
                        resultText = text;
                        translatedText = "";
                        translateError = "";
                        ToastService.showInfo("Scan complete!");
                        const translating = translateAfterScan;
                        if (!skipAutoCopy && (pluginData.autoCopy ?? true) && !(translating && copyWhich === "translation")) {
                            copyToClipboard(text);
                        }
                        if (translating) translateNow(true);
                    }
                } else {
                    scanError = describeTesseractError(exitCode, err, lang);
                    ToastService.showError(scanError);
                }
            },
            0,
            tesseractTimeoutMs
        );
    }

    function copyToClipboard(text) {
        if (!text) return;
        DMSService.sendRequest("clipboard.copy", { "text": text }, function(response) {
            if (!response.error) {
                ToastService.showInfo("Copied to clipboard!");
            }
        });
    }

    function saveResultToFile(translation) {
        savingTranslation = translation === true;
        saveContent = savingTranslation ? translatedText : resultText;
        if (!saveContent) return;
        isSaving = true;
        pluginRoot.closePopout();
        saveBrowserModal.open();
    }

    horizontalBarPill: Component {
        Item {
            implicitWidth: horizontalRow.implicitWidth
            implicitHeight: Theme.iconSize
            anchors.verticalCenter: parent.verticalCenter

            property bool draggingOver: false

            Row {
                id: horizontalRow
                spacing: Theme.spacingXS
                anchors.verticalCenter: parent.verticalCenter
                scale: draggingOver ? 1.2 : 1.0
                Behavior on scale { NumberAnimation { duration: 200; easing.type: Easing.OutBack } }

                DankIcon {
                    name: "document_scanner"
                    size: Theme.iconSizeSmall
                    color: draggingOver ? Theme.primary : (pluginRoot.isScanning ? Theme.primary : Theme.surfaceVariantText)
                    anchors.verticalCenter: parent.verticalCenter
                }
            }

            DropArea {
                anchors.fill: parent
                onEntered: draggingOver = true
                onExited: draggingOver = false
                onDropped: (drop) => {
                    draggingOver = false;
                    let urls = [];
                    if (drop.hasUrls) {
                        urls = drop.urls.map(url => url.toString());
                    } else if (drop.hasText) {
                        urls = [drop.text];
                    }
                    pluginRoot.triggerPopout();
                    if (urls.length > 0) {
                        urls.forEach(url => pluginRoot.scanFromUrl(url));
                    }
                }
            }

            MouseArea {
                anchors.fill: parent
                acceptedButtons: Qt.MiddleButton
                cursorShape: Qt.PointingHandCursor
                onClicked: (mouse) => {
                    if (mouse.button === Qt.MiddleButton) {
                        pluginRoot.scanFromScreenshot();
                    }
                }
            }
        }
    }

    FileBrowserModal {
        id: fileBrowserModal
        browserTitle: "Select Image to Scan"
        browserIcon: "image"
        fileExtensions: ["*.png", "*.jpg", "*.jpeg", "*.webp", "*.bmp"]
        onFileSelected: path => {
            pluginRoot.isScanning = true;
            pluginRoot.sourceImage = path;
            pluginRoot.imageTrigger++;
            pluginRoot.runTesseract(path);
            close();
        }
        onDialogClosed: {
            pluginRoot.triggerPopout();
        }
    }

    FileBrowserModal {
        id: saveBrowserModal
        browserTitle: pluginRoot.savingTranslation ? "Save Translation" : "Save OCR Result"
        browserIcon: "save"
        saveMode: true
        defaultFileName: pluginRoot.saveFileName
        fileExtensions: ["*.txt"]
        onFileSelected: filePath => {
            isSaving = true;
            
            let cleanPath = filePath;
            if (cleanPath.startsWith("file://")) {
                cleanPath = cleanPath.substring(7);
            } else if (cleanPath.startsWith("file: ")) {
                cleanPath = cleanPath.substring(6);
            }
            
            Proc.runCommand(
                "write-file",
                ["sh", "-c", "printf '%s' \"$1\" > \"$2\"", "sh", pluginRoot.saveContent, cleanPath],
                (stdout, exitCode) => {
                    isSaving = false;
                    if (exitCode === 0) {
                        ToastService.showInfo("Saved successfully!");
                    } else {
                        ToastService.showError("Failed to save: " + exitCode);
                    }
                },
                0
            );
            close();
        }
        onDialogClosed: isSaving = false
    }

    verticalBarPill: horizontalBarPill

    popoutContent: Component {
        PopoutComponent {
            id: popout
            width: parent ? parent.width : 0
            headerText: "OCR Scanner"
            detailsText: pluginRoot.isScanning ? "Scanning... " + pluginRoot.scanSeconds + " s" : "Ready to scan"
            showCloseButton: true
            focus: true

            property var parentPopout: null

            Connections {
                target: popout.parentPopout
                ignoreUnknownSignals: true
                function onShouldBeVisibleChanged() {
                    if (!popout.parentPopout.shouldBeVisible) pluginRoot.resetWindowState();
                }
            }

            Component.onDestruction: {
                pluginRoot.resetWindowState();
                if (!pluginRoot.isSaving && pluginRoot.pluginData && !(pluginRoot.pluginData.keepResults ?? true)) {
                    resultText = "";
                    translatedText = "";
                    sourceImage = "";
                }
            }

            DankFlickable {
                width: parent.width
                height: Math.min(contentHeight, pluginRoot.popoutHeight - popout.headerHeight - popout.detailsHeight - Theme.spacingM)
                contentHeight: contentColumn.implicitHeight
                contentWidth: width
                clip: true

                Column {
                    id: contentColumn
                    width: parent.width
                    spacing: Theme.spacingM

                    HintSection {
                        visible: !pluginRoot.outputMaximized
                        showHints: (pluginData.showHints ?? true)
                        width: parent.width

                        HintItem {
                            icon: "file_download"
                            text: I18n.trFor("ocrTranslate", "Drop an image or URL onto the pill icon to scan it instantly")
                        }
                        HintItem {
                            icon: "mouse"
                            text: I18n.trFor("ocrTranslate", "Right-click to scan clipboard, Middle-click to scan screenshot")
                        }
                    }

                    // What is going on, and the one Stop button for all of it (scan and translation).
                    Row {
                        width: parent.width
                        height: stopButton.height
                        spacing: Theme.spacingS

                        StyledText {
                            width: parent.width - stopButton.width - Theme.spacingS
                            anchors.verticalCenter: parent.verticalCenter
                            elide: Text.ElideRight
                            font.pixelSize: Theme.fontSizeSmall
                            color: Theme.primary
                            text: {
                                const parts = [];
                                if (pluginRoot.isScanning)
                                    parts.push(pluginRoot.ocrRunning ? "Scanning " + pluginRoot.scanSeconds + " s" : "Waiting for the image");
                                if (pluginRoot.isTranslating)
                                    parts.push("Translating" + (pluginRoot.translateProgress !== "" ? " · " + pluginRoot.translateProgress : "") + " · " + pluginRoot.translateSeconds + " s");
                                return parts.join("  ·  ");
                            }
                        }

                        DankButton {
                            id: stopButton
                            text: "Stop"
                            iconName: "stop_circle"
                            width: 96
                            onClicked: pluginRoot.stopAll()
                            enabled: pluginRoot.isScanning || pluginRoot.isTranslating
                            backgroundColor: Theme.errorContainer
                            textColor: Theme.error
                        }
                    }

                    // Recognition languages for this session: pick a few, add more when a scan needs them.
                    StyledRect {
                        visible: !pluginRoot.outputMaximized
                        width: parent.width
                        height: langColumn.implicitHeight + Theme.spacingM * 2
                        radius: Theme.cornerRadius
                        color: Theme.surfaceContainer
                        border.color: pluginRoot.langsChanged ? Theme.primary : Theme.outlineVariant
                        border.width: 1

                        Column {
                            id: langColumn
                            anchors.left: parent.left
                            anchors.right: parent.right
                            anchors.top: parent.top
                            anchors.margins: Theme.spacingM
                            spacing: Theme.spacingS

                            Row {
                                width: parent.width
                                spacing: Theme.spacingS

                                MouseArea {
                                    width: parent.width - resetLangs.width - Theme.spacingS
                                    height: resetLangs.height
                                    cursorShape: Qt.PointingHandCursor
                                    onClicked: pluginRoot.langExpanded = !pluginRoot.langExpanded

                                    Row {
                                        anchors.verticalCenter: parent.verticalCenter
                                        spacing: Theme.spacingS

                                        DankIcon {
                                            name: pluginRoot.langExpanded ? "expand_less" : "expand_more"
                                            size: Theme.iconSizeSmall
                                            color: Theme.surfaceVariantText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            text: "Recognition languages: " + pluginRoot.selectedOcrLangs.join(", ")
                                                + (pluginRoot.langsChanged ? " (this session)" : "")
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: Font.Medium
                                            color: Theme.surfaceText
                                            anchors.verticalCenter: parent.verticalCenter
                                        }

                                        StyledText {
                                            visible: pluginRoot.sourceImage !== "" && pluginRoot.lastScanLang !== "" && pluginRoot.lastScanLang !== pluginRoot.effectiveOcrLanguage
                                            text: "· Re-scan to apply"
                                            font.pixelSize: Theme.fontSizeSmall
                                            color: Theme.primary
                                            anchors.verticalCenter: parent.verticalCenter
                                        }
                                    }
                                }

                                DankButton {
                                    id: resetLangs
                                    text: "Reset"
                                    iconName: "restart_alt"
                                    onClicked: pluginRoot.sessionLangs = null
                                    enabled: pluginRoot.sessionLangs !== null
                                    backgroundColor: Theme.surfaceContainerHighest
                                    textColor: Theme.surfaceText
                                }
                            }

                            Flow {
                                id: langFlow
                                width: parent.width
                                spacing: Theme.spacingXS
                                visible: pluginRoot.langExpanded

                                Repeater {
                                    model: pluginRoot.installedOcrLangs

                                    delegate: Rectangle {
                                        readonly property bool picked: pluginRoot.selectedOcrLangs.indexOf(modelData) >= 0
                                        width: chipText.implicitWidth + Theme.spacingM * 2
                                        height: 28
                                        radius: Theme.cornerRadius
                                        color: picked ? Theme.primary : Theme.surfaceContainerHigh

                                        StyledText {
                                            id: chipText
                                            anchors.centerIn: parent
                                            text: modelData
                                            font.pixelSize: Theme.fontSizeSmall
                                            font.weight: parent.picked ? Font.Bold : Font.Normal
                                            color: parent.picked ? Theme.onPrimary : Theme.surfaceText
                                        }

                                        MouseArea {
                                            anchors.fill: parent
                                            cursorShape: Qt.PointingHandCursor
                                            onClicked: pluginRoot.toggleSessionLang(modelData)
                                        }
                                    }
                                }
                            }

                            StyledText {
                                width: parent.width
                                visible: pluginRoot.langExpanded
                                text: "Only for this session: a restart or Reset goes back to the default list in the settings. The first language also sets the translation source. Fewer languages scan faster."
                                wrapMode: Text.WordWrap
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.surfaceVariantText
                            }
                        }
                    }

                    Row {
                        width: parent.width
                        spacing: Theme.spacingM

                        Column {
                            visible: !pluginRoot.outputMaximized
                            width: (parent.width - Theme.spacingM * 2) / 3
                            spacing: Theme.spacingM

                            StyledRect {
                                width: parent.width
                                height: pluginRoot.boxHeight
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainer
                                border.color: Theme.outlineVariant
                                border.width: 1
                                clip: true

                                Image {
                                    id: sourceImg
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingM
                                    fillMode: Image.PreserveAspectFit
                                    asynchronous: true
                                    source: pluginRoot.sourceImage ? "file://" + pluginRoot.sourceImage + "?t=" + pluginRoot.imageTrigger : ""

                                    StyledText {
                                        anchors.centerIn: parent
                                        text: I18n.trFor("ocrTranslate", "No image scanned yet")
                                        color: Theme.outlineVariant
                                        visible: sourceImg.status !== Image.Ready && !pluginRoot.isScanning
                                        font.pixelSize: Theme.fontSizeMedium
                                    }
                                }

                                DankButton {
                                    anchors.top: parent.top
                                    anchors.right: parent.right
                                    anchors.margins: Theme.spacingS
                                    width: 32
                                    height: 32
                                    iconName: "delete"
                                    onClicked: {
                                        pluginRoot.sourceImage = ""
                                        pluginRoot.resultText = ""
                                        pluginRoot.translatedText = ""
                                        pluginRoot.translateError = ""
                                        pluginRoot.lastTranslateKey = ""
                                    }
                                    enabled: (pluginRoot.sourceImage !== "" || pluginRoot.resultText !== "") && !pluginRoot.isScanning
                                    backgroundColor: Theme.errorContainer
                                    textColor: Theme.error
                                }
                            }

                            Row {
                                width: parent.width
                                spacing: Theme.spacingS

                                DankButton {
                                    text: "Capture"
                                    width: (parent.width - Theme.spacingS * 2) / 3
                                    iconName: "screenshot_region"
                                    onClicked: {
                                        pluginRoot.closePopout();
                                        captureTimer.restart();
                                    }
                                    enabled: !pluginRoot.isScanning
                                    backgroundColor: Theme.primaryContainer
                                    textColor: Theme.primary
                                }

                                DankButton {
                                    text: "Clipboard"
                                    width: (parent.width - Theme.spacingS * 2) / 3
                                    iconName: "content_paste"
                                    onClicked: pluginRoot.scanFromClipboard()
                                    enabled: !pluginRoot.isScanning
                                    backgroundColor: Theme.surfaceContainerHighest
                                    textColor: Theme.surfaceText
                                }

                                DankButton {
                                    text: "Open image"
                                    width: (parent.width - Theme.spacingS * 2) / 3
                                    iconName: "image"
                                    onClicked: pluginRoot.selectFileAndScan()
                                    enabled: !pluginRoot.isScanning
                                    backgroundColor: Theme.surfaceContainerHighest
                                    textColor: Theme.surfaceText
                                }
                            }
                        }

                        Column {
                            visible: !pluginRoot.outputMaximized
                            width: (parent.width - Theme.spacingM * 2) / 3
                            spacing: Theme.spacingM

                            StyledRect {
                                width: parent.width
                                height: pluginRoot.boxHeight
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainer
                                border.color: pluginRoot.isScanning ? Theme.primary : Theme.outlineVariant
                                border.width: 1

                                DankFlickable {
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingM
                                    contentWidth: width - (Theme.spacingM * 2)
                                    contentHeight: resultArea.implicitHeight
                                    clip: true

                                    TextEdit {
                                        id: resultArea
                                        width: parent.width
                                        text: pluginRoot.resultText
                                        wrapMode: TextEdit.Wrap
                                        font.pixelSize: Theme.fontSizeMedium
                                        color: Theme.surfaceText
                                        selectByMouse: true
                                        onTextChanged: {
                                            // Text that differs from what the plugin holds was typed or pasted here; scan
                                            // results and swaps change resultText first, so the two already match then.
                                            const edited = text !== pluginRoot.resultText;
                                            pluginRoot.resultText = text;
                                            if (edited && pluginRoot.translateOnEdit) editTimer.restart();
                                        }

                                        Text {
                                            text: I18n.trFor("ocrTranslate", "Type, paste or scan text here...")
                                            color: Theme.outlineVariant
                                            visible: resultArea.text === ""
                                            font: resultArea.font
                                        }
                                    }
                                }
                            }

                            Row {
                                width: parent.width
                                spacing: Theme.spacingS

                                DankButton {
                                    text: "Re-scan"
                                    width: (parent.width - Theme.spacingS * 2) / 3
                                    iconName: "refresh"
                                    onClicked: pluginRoot.rescan()
                                    enabled: pluginRoot.sourceImage !== "" && (!pluginRoot.isScanning || pluginRoot.ocrRunning)
                                    backgroundColor: Theme.surfaceContainerHighest
                                    textColor: Theme.surfaceText
                                }

                                DankButton {
                                    text: I18n.trFor("ocrTranslate", "Copy Text")
                                    width: (parent.width - Theme.spacingS * 2) / 3
                                    iconName: "content_copy"
                                    onClicked: pluginRoot.copyToClipboard(pluginRoot.resultText)
                                    enabled: pluginRoot.resultText !== "" && !pluginRoot.isScanning
                                    backgroundColor: Theme.primaryContainer
                                    textColor: Theme.primary
                                }

                                DankButton {
                                    text: I18n.trFor("ocrTranslate", "Save Text")
                                    width: (parent.width - Theme.spacingS * 2) / 3
                                    iconName: "save"
                                    onClicked: pluginRoot.saveResultToFile()
                                    enabled: pluginRoot.resultText !== "" && !pluginRoot.isScanning
                                    backgroundColor: Theme.surfaceContainerHighest
                                    textColor: Theme.surfaceText
                                }
                            }

                            StyledText {
                                width: parent.width
                                visible: pluginRoot.scanError !== ""
                                text: pluginRoot.scanError
                                wrapMode: Text.WordWrap
                                font.pixelSize: Theme.fontSizeSmall
                                color: Theme.error
                            }
                        }

                        Column {
                            width: pluginRoot.outputMaximized ? parent.width : (parent.width - Theme.spacingM * 2) / 3
                            spacing: Theme.spacingM

                            Row {
                                id: languageRow
                                width: parent.width
                                spacing: Theme.spacingS

                                DankDropdown {
                                    width: (parent.width - swapButton.width - Theme.spacingS * 2) / 2
                                    dropdownWidth: width
                                    compactMode: true
                                    enableFuzzySearch: true
                                    options: pluginRoot.fromOptions
                                    currentValue: {
                                        const language = Translator.languageByCode(pluginRoot.fromCode);
                                        return language ? Translator.languageLabel(language) : pluginRoot.autoFromLabel;
                                    }
                                    onValueChanged: value => pluginRoot.setLanguage("sourceLang", value, value === pluginRoot.autoFromLabel)
                                }

                                DankButton {
                                    id: swapButton
                                    width: 40
                                    height: 40
                                    iconName: "swap_horiz"
                                    onClicked: pluginRoot.swapLanguagesAndText()
                                    enabled: !pluginRoot.isScanning && (pluginRoot.resultText !== "" || pluginRoot.translatedText !== "")
                                    backgroundColor: Theme.surfaceContainerHighest
                                    textColor: Theme.surfaceText
                                }

                                DankDropdown {
                                    width: (parent.width - swapButton.width - Theme.spacingS * 2) / 2
                                    dropdownWidth: width
                                    compactMode: true
                                    enableFuzzySearch: true
                                    options: pluginRoot.toOptions
                                    currentValue: {
                                        const language = Translator.languageByCode(pluginRoot.toCode);
                                        return language ? Translator.languageLabel(language) : "";
                                    }
                                    onValueChanged: value => pluginRoot.setLanguage("targetLang", value, false)
                                }
                            }

                            StyledRect {
                                width: parent.width
                                height: pluginRoot.boxHeight - languageRow.height - Theme.spacingM
                                radius: Theme.cornerRadius
                                color: Theme.surfaceContainer
                                border.color: pluginRoot.isTranslating ? Theme.primary : Theme.outlineVariant
                                border.width: 1

                                DankFlickable {
                                    id: translationFlick
                                    anchors.fill: parent
                                    anchors.margins: Theme.spacingM
                                    contentWidth: width - (Theme.spacingM * 2)
                                    contentHeight: translationArea.implicitHeight
                                    clip: true

                                    // Follow the text as it is typed out, but only while the view is at its end: scrolling
                                    // up to read an earlier part stops it, scrolling back down to the end resumes it.
                                    property bool followEnd: true
                                    property bool followScrolling: false
                                    function atEnd() {
                                        return contentY + height >= contentHeight - 4;
                                    }
                                    onContentYChanged: if (!followScrolling) followEnd = atEnd()
                                    onContentHeightChanged: {
                                        if (pluginRoot.isTranslating && followEnd) {
                                            followScrolling = true;
                                            contentY = Math.max(0, contentHeight - height);
                                            followScrolling = false;
                                        }
                                    }

                                    Connections {
                                        target: pluginRoot
                                        // A new translation starts at the top of an empty box.
                                        function onIsTranslatingChanged() {
                                            if (pluginRoot.isTranslating) translationFlick.followEnd = true;
                                        }
                                    }

                                    TextEdit {
                                        id: translationArea
                                        width: parent.width
                                        text: pluginRoot.translatedText
                                        readOnly: true
                                        wrapMode: TextEdit.Wrap
                                        font.pixelSize: Theme.fontSizeMedium
                                        color: Theme.surfaceText
                                        selectByMouse: true

                                        Text {
                                            text: pluginRoot.isTranslating ? "Translating..." : "Translation will appear here..."
                                            color: Theme.outlineVariant
                                            visible: translationArea.text === ""
                                            font: translationArea.font
                                        }
                                    }
                                }

                                DankButton {
                                    anchors.top: parent.top
                                    anchors.right: parent.right
                                    anchors.margins: Theme.spacingS
                                    width: 32
                                    height: 32
                                    iconName: pluginRoot.outputMaximized ? "close_fullscreen" : "open_in_full"
                                    onClicked: pluginRoot.outputMaximized = !pluginRoot.outputMaximized
                                    backgroundColor: Theme.surfaceContainerHighest
                                    textColor: Theme.surfaceText
                                }
                            }

                            Row {
                                width: parent.width
                                spacing: Theme.spacingS

                                DankButton {
                                    text: "Translate"
                                    width: (parent.width - Theme.spacingS * 2) / 3
                                    iconName: "translate"
                                    onClicked: pluginRoot.translateNow(false)
                                    enabled: pluginRoot.resultText.trim() !== "" && !pluginRoot.isScanning && !pluginRoot.isTranslating
                                    backgroundColor: Theme.primaryContainer
                                    textColor: Theme.primary
                                }

                                DankButton {
                                    text: "Copy"
                                    width: (parent.width - Theme.spacingS * 2) / 3
                                    iconName: "content_copy"
                                    onClicked: pluginRoot.copyToClipboard(pluginRoot.translatedText)
                                    enabled: pluginRoot.translatedText !== ""
                                    backgroundColor: Theme.surfaceContainerHighest
                                    textColor: Theme.surfaceText
                                }

                                DankButton {
                                    text: "Save"
                                    width: (parent.width - Theme.spacingS * 2) / 3
                                    iconName: "save"
                                    onClicked: pluginRoot.saveResultToFile(true)
                                    enabled: pluginRoot.translatedText !== ""
                                    backgroundColor: Theme.surfaceContainerHighest
                                    textColor: Theme.surfaceText
                                }
                            }

                            StyledText {
                                width: parent.width
                                visible: text !== ""
                                text: pluginRoot.translateError !== "" ? pluginRoot.translateError : pluginRoot.translateInfo
                                wrapMode: Text.WordWrap
                                font.pixelSize: Theme.fontSizeSmall
                                color: pluginRoot.translateError !== "" ? Theme.error : Theme.surfaceVariantText
                            }
                        }
                    }
                }
            }
        }
    }

}
