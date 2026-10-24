import QtQuick
import QtQuick.Controls
import qs.Common
import qs.Widgets
import qs.DCommon.Widgets
import qs.Modules.Plugins
import "./shared"
import "./Translator.js" as Translator

PluginSettings {
    id: root
    pluginId: "ocrTranslate"

    readonly property string defaultOcrLanguage: "eng"
    property var availableLangs: []
    property var selectedLangs: []

    // Models the translation server lists (names like translategemma:4b@NPU).
    property var serverModels: []
    property string modelsError: ""

    function loadModels() {
        const url = root.pluginService ? root.loadValue("serverUrl", Translator.DEFAULT_URL) : Translator.DEFAULT_URL;
        Translator.listModels(url || Translator.DEFAULT_URL, (error, names) => {
            root.modelsError = error;
            root.serverModels = names;
        });
    }

    function loadSettings() {
        let val = root.defaultOcrLanguage;
        if (root.pluginService) {
            val = root.loadValue("ocrLanguage", root.defaultOcrLanguage);
        }
        if (val === undefined || val === null) {
            val = root.defaultOcrLanguage;
        }
        selectedLangs = String(val).split("+").filter(s => s !== "");
    }

    function toggleLang(lang) {
        let list = selectedLangs.slice();
        let index = list.indexOf(lang);
        if (index >= 0) {
            list.splice(index, 1);
        } else {
            list.push(lang);
        }
        
        let newVal = list.join("+");
        root.saveValue("ocrLanguage", newVal);
        
        // Update local state to trigger UI
        selectedLangs = list;
    }

    Connections {
        target: root.pluginService
        enabled: root.pluginService !== null

        function onPluginDataChanged(changedPluginId) {
            if (changedPluginId === root.pluginId) {
                root.loadSettings();
            }
        }
    }

    Component.onCompleted: {
        Qt.callLater(loadSettings);
        Proc.runCommand(
            "list-langs",
            ["tesseract", "--list-langs"],
            (stdout, exitCode) => {
                if (exitCode === 0) {
                    var lines = stdout.split("\n");
                    var langs = [];
                    for (var i = 1; i < lines.length; i++) {
                        var l = lines[i].trim();
                        if (l !== "" && l !== "osd") langs.push(l);
                    }
                    availableLangs = langs.sort();
                }
            },
            0
        );
    }

    onPluginServiceChanged: {
        loadSettings();
        loadModels();
    }

    SettingsCard {
        SectionTitle { text: I18n.trFor("ocrTranslate", "Recognition Languages"); icon: "language" }

        Flow {
            id: langFlow
            width: parent.width
            spacing: Theme.spacingS

            Repeater {
                model: root.availableLangs
                delegate: Rectangle {
                    width: (langFlow.width - (Theme.spacingS * 2)) / 3
                    height: 36
                    radius: Theme.cornerRadius
                    color: root.selectedLangs.indexOf(modelData) >= 0 ? Theme.primary : Theme.surfaceContainerHigh
                    
                    Row {
                        anchors.centerIn: parent
                        spacing: Theme.spacingXS
                        DIcon {
                            name: root.selectedLangs.indexOf(modelData) >= 0 ? "check_circle" : "radio_button_unchecked"
                            size: 14
                            color: root.selectedLangs.indexOf(modelData) >= 0 ? Theme.onPrimary : Theme.surfaceVariantText
                        }
                        StyledText {
                            text: modelData.toUpperCase()
                            font.pixelSize: Theme.fontSizeSmall
                            font.weight: root.selectedLangs.indexOf(modelData) >= 0 ? Font.Bold : Font.Normal
                            color: root.selectedLangs.indexOf(modelData) >= 0 ? Theme.onPrimary : Theme.surfaceText
                        }
                    }

                    MouseArea {
                        anchors.fill: parent
                        cursorShape: Qt.PointingHandCursor
                        onClicked: root.toggleLang(modelData)
                    }
                }
            }
        }
    }

    SettingsCard {
        SectionTitle { 
            text: I18n.trFor("ocrTranslate", "Behavior")
            icon: "settings" 
            showReset: autoCopy.isDirty || fixThaiSpacing.isDirty || keepResults.isDirty || showPopout.isDirty || showHints.isDirty
            onResetClicked: {
                autoCopy.resetToDefault();
                fixThaiSpacing.resetToDefault();
                keepResults.resetToDefault();
                showPopout.resetToDefault();
                showHints.resetToDefault();
            }
        }

        ToggleSettingPlus {
            id: autoCopy
            settingKey: "autoCopy"
            label: I18n.trFor("ocrTranslate", "Auto-copy to Clipboard")
            defaultValue: true
        }

        Separator { leftMargin: Theme.spacingM; rightMargin: Theme.spacingM }

        ToggleSettingPlus {
            id: fixThaiSpacing
            settingKey: "fixThaiSpacing"
            label: "Remove spaces inside Thai words"
            defaultValue: true
        }

        Separator { leftMargin: Theme.spacingM; rightMargin: Theme.spacingM }

        ToggleSettingPlus {
            id: keepResults
            settingKey: "keepResults"
            label: I18n.trFor("ocrTranslate", "Keep results when closed")
            defaultValue: true
        }

        Separator { leftMargin: Theme.spacingM; rightMargin: Theme.spacingM }

        ToggleSettingPlus {
            id: showPopout
            settingKey: "showPopoutOnRightClick"
            label: I18n.trFor("ocrTranslate", "Show popout on right-click")
            defaultValue: true
        }

        Separator { leftMargin: Theme.spacingM; rightMargin: Theme.spacingM }

        ToggleSettingPlus {
            id: showHints
            settingKey: "showHints"
            label: I18n.trFor("ocrTranslate", "Show Hints")
            defaultValue: true
        }
    }

    SettingsCard {
        SectionTitle { text: "Translation"; icon: "translate" }

        InfoText {
            text: "Translates the scanned text with an Ollama-compatible server, like the Llama Franca browser extension (TranslateGemma on the NPU translator or Ollama)."
        }

        StringSetting {
            settingKey: "serverUrl"
            label: "Server"
            description: "Address of the server. Re-open this page after changing it to reload the model list."
            placeholder: Translator.DEFAULT_URL
            defaultValue: Translator.DEFAULT_URL
        }

        SelectionSetting {
            settingKey: "model"
            label: "Model"
            description: root.modelsError !== "" ? root.modelsError
                : "Names ending in @NPU, @GPU or @CPU run on that device; the plain name uses the server's default device."
            options: root.serverModels.length > 0 ? root.serverModels.map(name => ({ label: name, value: name }))
                                                  : [{ label: Translator.DEFAULT_MODEL, value: Translator.DEFAULT_MODEL }]
            defaultValue: Translator.DEFAULT_MODEL
        }

        SelectionSetting {
            settingKey: "targetLang"
            label: "Translate into"
            description: "Can also be changed in the scanner window."
            options: Translator.LANGUAGES.map(l => ({ label: Translator.languageLabel(l), value: l.code }))
            defaultValue: "en"
        }

        ToggleSettingPlus {
            settingKey: "translateAfterScan"
            label: "Translate after every scan"
            defaultValue: true
        }

        ToggleSettingPlus {
            settingKey: "translateOnEdit"
            label: "Translate while typing"
            defaultValue: true
        }

        SelectionSetting {
            settingKey: "copyWhich"
            label: "Auto-copy"
            description: "Which text goes to the clipboard after a scan when translating after every scan."
            options: [
                { label: "Translation", value: "translation" },
                { label: "Scanned text", value: "original" }
            ]
            defaultValue: "translation"
        }
    }

    SettingsCard {
        SectionTitle { text: I18n.trFor("ocrTranslate", "Installation"); icon: "download" }

        InfoText {
            text: I18n.trFor("ocrTranslate", "Install the required packages:")
        }

        Column {
            width: parent.width
            spacing: Theme.spacingS

            Repeater {
                model: [
                    { cmd: "sudo dnf install tesseract tesseract-langpack-eng tesseract-langpack-vie wl-clipboard", label: "Fedora" },
                    { cmd: "sudo pacman -S tesseract tesseract-data-eng tesseract-data-vie wl-clipboard", label: "Arch Linux" },
                    { cmd: "sudo apt install tesseract tesseract-ocr-eng tesseract-ocr-vie wl-clipboard", label: "Debian/Ubuntu" },
                    { cmd: "sudo zypper install tesseract tesseract-langpack-en tesseract-langpack-vi wl-clipboard", label: "openSUSE" }
                ]

                delegate: CopyBox {
                    label: modelData.label
                    text: modelData.cmd
                }
            }
        }
    }

    SettingsCard {
        SectionTitle { 
            id: usageTitle
            text: I18n.trFor("ocrTranslate", "Usage Guide")
            icon: "menu_book" 
            collapsible: true
            settingKey: "usageGuideExpanded"
        }

        UsageGuide {
            expanded: usageTitle.isExpanded
            items: [
                I18n.trFor("ocrTranslate", "<b>Left-click</b> the pill to start a new screen scan."),
                I18n.trFor("ocrTranslate", "<b>Right-click</b> the pill to perform a quick scan or open results."),
                I18n.trFor("ocrTranslate", "Dropping an <b>image</b> onto the pill will scan it for text."),
                I18n.trFor("ocrTranslate", "Scanned text is automatically copied to the <b>clipboard</b>.")
            ]
        }
    }
}
