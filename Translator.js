.pragma library

// Translation through an Ollama-compatible API (Ollama, or local-llm-npu-translator on the
// same port). Ported from llama-franca (src/lib/ollama.ts, prefs.ts, models.ts, languages.ts)
// so the plugin prompts TranslateGemma exactly like the browser extension does.

var DEFAULT_URL = "http://localhost:11434";
var DEFAULT_MODEL = "translategemma:4b";

// Exact template from https://ollama.com/library/translategemma.
var DEFAULT_PROMPT = "You are a professional {source} ({source_code}) to {target} ({target_code}) translator. Your goal is to accurately convey the meaning and nuances of the original {source} text while adhering to {target} grammar, vocabulary, and cultural sensitivities.\n" +
    "Produce only the {target} translation, without any additional explanations or commentary. Please translate the following {source} text into {target}:\n\n\n{text}";

// code and name as the prompt uses them; label is what the pickers show when it differs.
var LANGUAGES = [
    { code: "ar", name: "Arabic" },
    { code: "bn", name: "Bengali" },
    { code: "my", name: "Burmese" },
    { code: "zh-Hans", name: "Chinese", label: "Chinese (Simplified)" },
    { code: "zh-Hant", name: "Chinese", label: "Chinese (Traditional)" },
    { code: "cs", name: "Czech" },
    { code: "da", name: "Danish" },
    { code: "nl", name: "Dutch" },
    { code: "en", name: "English" },
    { code: "et", name: "Estonian" },
    { code: "fi", name: "Finnish" },
    { code: "fr", name: "French" },
    { code: "de", name: "German" },
    { code: "el", name: "Greek" },
    { code: "he", name: "Hebrew" },
    { code: "hi", name: "Hindi" },
    { code: "hu", name: "Hungarian" },
    { code: "is", name: "Icelandic" },
    { code: "id", name: "Indonesian" },
    { code: "it", name: "Italian" },
    { code: "ja", name: "Japanese" },
    { code: "km", name: "Central Khmer", label: "Khmer" },
    { code: "ko", name: "Korean" },
    { code: "lo", name: "Lao" },
    { code: "ms", name: "Malay" },
    { code: "no", name: "Norwegian" },
    { code: "fa", name: "Persian" },
    { code: "pl", name: "Polish" },
    { code: "pt", name: "Portuguese" },
    { code: "ro", name: "Romanian" },
    { code: "ru", name: "Russian" },
    { code: "es", name: "Spanish" },
    { code: "sv", name: "Swedish" },
    { code: "tl", name: "Tagalog" },
    { code: "th", name: "Thai" },
    { code: "tr", name: "Turkish" },
    { code: "uk", name: "Ukrainian" },
    { code: "vi", name: "Vietnamese" }
];

// Tesseract language code -> the translation language it reads.
var TESSERACT_TO_CODE = {
    eng: "en", est: "et", fin: "fi", swe: "sv", nor: "no", dan: "da", isl: "is", fao: "da",
    rus: "ru", ukr: "uk", jpn: "ja", jpn_vert: "ja", kor: "ko", deu: "de", fra: "fr",
    spa: "es", ita: "it", por: "pt", nld: "nl", pol: "pl", ces: "cs", hun: "hu", ron: "ro",
    ell: "el", heb: "he", ara: "ar", fas: "fa", hin: "hi", tha: "th", vie: "vi", tur: "tr",
    ind: "id", msa: "ms", chi_sim: "zh-Hans", chi_sim_vert: "zh-Hans",
    chi_tra: "zh-Hant", chi_tra_vert: "zh-Hant"
};

function languageLabel(language) {
    return language.label || language.name;
}

function languageByCode(code) {
    for (var i = 0; i < LANGUAGES.length; i++)
        if (LANGUAGES[i].code === code) return LANGUAGES[i];
    return undefined;
}

function languageByLabel(label) {
    for (var i = 0; i < LANGUAGES.length; i++)
        if (languageLabel(LANGUAGES[i]) === label) return LANGUAGES[i];
    return undefined;
}

// "eng+est" -> the language of the first Tesseract language we know, "" when none.
function sourceFromOcr(ocrLanguages) {
    var parts = String(ocrLanguages || "").split("+");
    for (var i = 0; i < parts.length; i++)
        if (TESSERACT_TO_CODE[parts[i]]) return TESSERACT_TO_CODE[parts[i]];
    return "";
}

function buildPrompt(template, source, target, text) {
    var values = {
        "{source}": source.name,
        "{source_code}": source.code,
        "{target}": target.name,
        "{target_code}": target.code,
        "{text}": text
    };
    return template.replace(/\{\w+\}/g, function (match) {
        return values[match] !== undefined ? values[match] : match;
    });
}

// A server that runs a model on several devices (local-llm-npu-translator) lists one name per
// device besides the plain one: `translategemma:4b`, `translategemma:4b@NPU`, ...
var DEVICES = ["NPU", "GPU", "CPU"];

function splitModel(name) {
    var at = name.lastIndexOf("@");
    var device = at > 0 ? name.slice(at + 1).toUpperCase() : "";
    return DEVICES.indexOf(device) >= 0 ? { model: name.slice(0, at), device: device } : { model: name, device: "" };
}

// Model names without device variants, and the devices each one is listed with.
function groupModels(names) {
    var models = [];
    var devices = {};
    for (var i = 0; i < names.length; i++) {
        var parts = splitModel(names[i]);
        if (!devices[parts.model]) {
            devices[parts.model] = [];
            models.push(parts.model);
        }
        if (parts.device) devices[parts.model].push(parts.device);
    }
    return { models: models, devices: devices };
}

// callback(error, json). error is a message for the user, or "".
function request(serverUrl, path, body, model, callback) {
    var xhr = new XMLHttpRequest();
    var base = String(serverUrl || DEFAULT_URL).replace(/\/+$/, "");
    xhr.open(body === undefined ? "GET" : "POST", base + path);
    xhr.onreadystatechange = function () {
        if (xhr.readyState !== XMLHttpRequest.DONE) return;
        if (xhr.status === 0) {
            callback("Ollama is not reachable at " + base + ". Is it running?", null);
            return;
        }
        var json = {};
        try { json = JSON.parse(xhr.responseText); } catch (e) { json = {}; }
        if (xhr.status === 403)
            callback("The server refused the request (" + (json.error || "403") + ")", null);
        else if (xhr.status === 404 && model && /model/i.test(json.error || ""))
            callback("Model " + model + " isn't installed. Run: ollama pull " + model + ", or pick another in the settings.", null);
        else if (xhr.status < 200 || xhr.status >= 300)
            callback(json.error || "Ollama responded " + xhr.status, null);
        else
            callback("", json);
    };
    if (body === undefined) {
        xhr.send();
    } else {
        xhr.setRequestHeader("Content-Type", "application/json");
        xhr.send(JSON.stringify(body));
    }
    return xhr;
}

// callback(error, names[])
function listModels(serverUrl, callback) {
    return request(serverUrl, "/api/tags", undefined, "", function (error, json) {
        if (error) { callback(error, []); return; }
        var names = (json.models || []).map(function (m) { return m.name; });
        names.sort();
        callback("", names);
    });
}

var cache = {};

function clearCache() {
    cache = {};
}

// One streamed chat: Ollama's /api/chat with stream:true answers with one JSON object per line, each
// carrying the next bit of text; the last has done:true and the timings. A server that ignores stream
// answers with one object, which reads the same way. QML's XMLHttpRequest hands over the response as it
// arrives (readyState 3). onText(textSoFar) after every line; callback(error, { text, tokensPerSecond }).
function streamChat(serverUrl, body, model, onText, callback) {
    var base = String(serverUrl || DEFAULT_URL).replace(/\/+$/, "");
    var xhr = new XMLHttpRequest();
    var consumed = 0;
    var text = "";
    var speed = 0;
    var failure = "";
    var finished = false;

    function readLines(final) {
        var data = xhr.responseText;
        var end = data.lastIndexOf("\n") + 1;
        if (final) end = data.length;
        var chunk = data.slice(consumed, end);
        consumed = end;
        var lines = chunk.split("\n");
        var grew = false;
        for (var i = 0; i < lines.length; i++) {
            if (lines[i].trim() === "") continue;
            var obj;
            try { obj = JSON.parse(lines[i]); } catch (e) { continue; }
            if (obj.error) {
                failure = typeof obj.error === "string" ? obj.error : (obj.error.message || "error");
                continue;
            }
            if (obj.message && obj.message.content) {
                text += obj.message.content;
                grew = true;
            }
            if (obj.done && obj.eval_count && obj.eval_duration) speed = obj.eval_count / (obj.eval_duration / 1e9);
        }
        if (grew) onText(text);
    }

    xhr.open("POST", base + "/api/chat");
    xhr.setRequestHeader("Content-Type", "application/json");
    xhr.onreadystatechange = function () {
        if (finished) return;
        if (xhr.readyState === 3 && xhr.status === 200) {
            readLines(false);
        } else if (xhr.readyState === XMLHttpRequest.DONE) {
            finished = true;
            if (xhr.status === 0) {
                callback("Ollama is not reachable at " + base + ". Is it running?", null);
                return;
            }
            if (xhr.status < 200 || xhr.status >= 300) {
                var json = {};
                try { json = JSON.parse(xhr.responseText); } catch (e) { json = {}; }
                if (xhr.status === 403)
                    callback("The server refused the request (" + (json.error || "403") + ")", null);
                else if (xhr.status === 404 && model && /model/i.test(json.error || ""))
                    callback("Model " + model + " isn't installed. Run: ollama pull " + model + ", or pick another in the settings.", null);
                else
                    callback(json.error || "Ollama responded " + xhr.status, null);
                return;
            }
            readLines(true);
            if (failure !== "") callback(failure, text === "" ? null : { text: text.trim(), tokensPerSecond: 0 });
            else callback("", { text: text.trim(), tokensPerSecond: speed });
        }
    };
    xhr.send(JSON.stringify(body));
    return xhr;
}

// opts: serverUrl, model, template, source {code,name}, target {code,name}, text.
// onText(textSoFar) while it is produced; callback(error, { text, tokensPerSecond, cached }).
// Returns the XHR so a caller can abort it (null when the answer was cached).
function translate(opts, onText, callback) {
    var key = [opts.serverUrl, opts.model, opts.template, opts.source.code, opts.target.code, opts.text].join("\u0000");
    if (cache[key] !== undefined) {
        callback("", { text: cache[key], tokensPerSecond: 0, cached: true });
        return null;
    }
    var body = {
        model: opts.model,
        stream: true,
        // Greedy decoding keeps translations repeatable; the cap stops repetition loops.
        options: { temperature: 0, num_predict: opts.text.length * 2 + 64 },
        messages: [{ role: "user", content: buildPrompt(opts.template, opts.source, opts.target, opts.text) }]
    };
    return streamChat(opts.serverUrl, body, opts.model, onText, function (error, result) {
        if (error) { callback(error, null); return; }
        if (result.text !== "") cache[key] = result.text;
        callback("", { text: result.text, tokensPerSecond: result.tokensPerSecond, cached: false });
    });
}

// Tesseract's Thai model puts a space between nearly every character, including before vowel and
// tone marks ("ส ว ั ส ด ี"), which reads as floating vowels. Thai is written without spaces inside
// words, so spaces (not line breaks) between two Thai characters are dropped. Spaces next to digits
// or Latin text stay. Real spaces between Thai phrases are lost too.
function fixThaiSpacing(text) {
    return text.replace(/([\u0E00-\u0E7F])[ \t]+(?=[\u0E00-\u0E7F])/g, "$1");
}

// Long text goes in pieces, one request each, the way Llama Franca sends a page block by block and the NPU
// translator cuts long input into sentence groups: a long single request is slow with no sign of life, and a
// model asked for a long text can drop or merge repeated lines. Pieces also cache one by one, so editing one
// line of a long text only translates that piece again.
var MAX_CHUNK_CHARS = 900;

// Cut a line longer than max at sentence ends, else at a space, else mid-word (Thai has no spaces).
function cutLongLine(line, max) {
    var parts = line.match(/[^.!?。！？]+[.!?。！？]*\s*/g) || [line];
    var out = [];
    var current = "";
    for (var i = 0; i < parts.length; i++) {
        var part = parts[i];
        if (current !== "" && (current + part).length > max) {
            out.push(current);
            current = "";
        }
        current += part;
        while (current.length > max) {
            var cut = current.lastIndexOf(" ", max);
            if (cut < max / 2) cut = max;
            out.push(current.slice(0, cut));
            current = current.slice(cut);
        }
    }
    if (current !== "") out.push(current);
    return out;
}

// [{ text, sep }]: sep is what follows the piece in the original (a line break, or a space inside a cut line).
function splitChunks(text, maxChars) {
    var max = maxChars || MAX_CHUNK_CHARS;
    var lines = text.replace(/\r\n?/g, "\n").split("\n");
    var pieces = [];
    for (var i = 0; i < lines.length; i++) {
        var lineSep = i < lines.length - 1 ? "\n" : "";
        var parts = lines[i].length > max ? cutLongLine(lines[i], max) : [lines[i]];
        for (var j = 0; j < parts.length; j++)
            pieces.push({ text: parts[j].trim(), sep: j < parts.length - 1 ? " " : lineSep });
    }
    var chunks = [];
    var current = null;
    for (var k = 0; k < pieces.length; k++) {
        var piece = pieces[k];
        if (current !== null && current.text.length + current.sep.length + piece.text.length > max) {
            chunks.push(current);
            current = null;
        }
        if (current === null)
            current = { text: piece.text, sep: piece.sep };
        else
            current = { text: current.text + current.sep + piece.text, sep: piece.sep };
    }
    if (current !== null) chunks.push(current);
    return chunks;
}

// Like translate(), for any length. onProgress(done, total, textSoFar) after each piece;
// callback(error, { text, tokensPerSecond, cached, parts }). Returns { abort() }.
function translateLong(opts, onProgress, callback) {
    var chunks = splitChunks(opts.text);
    var results = [];
    var state = { aborted: false, xhr: null };
    var speeds = [];
    var allCached = true;
    var index = 0;

    function assemble(count) {
        var out = "";
        for (var i = 0; i < count; i++)
            out += results[i] + (i < count - 1 ? chunks[i].sep : "");
        return out;
    }

    function next() {
        if (state.aborted) return;
        if (index >= chunks.length) {
            var speed = 0;
            for (var i = 0; i < speeds.length; i++) speed += speeds[i];
            callback("", {
                text: assemble(chunks.length),
                tokensPerSecond: speeds.length > 0 ? speed / speeds.length : 0,
                cached: allCached,
                parts: chunks.length
            });
            return;
        }
        var chunk = chunks[index];
        if (chunk.text === "") {
            results.push("");
            index++;
            next();
            return;
        }
        var piece = {};
        for (var key in opts) piece[key] = opts[key];
        piece.text = chunk.text;
        var before = index > 0 ? assemble(index) + chunks[index - 1].sep : "";
        state.xhr = translate(piece, function (soFar) {
            if (!state.aborted) onProgress(index, chunks.length, before + soFar);
        }, function (error, result) {
            if (state.aborted) return;
            if (error) {
                callback(error, null);
                return;
            }
            results.push(result.text);
            if (!result.cached) allCached = false;
            if (result.tokensPerSecond) speeds.push(result.tokensPerSecond);
            index++;
            onProgress(index, chunks.length, assemble(index));
            next();
        });
    }

    onProgress(0, chunks.length, "");
    next();
    return {
        abort: function () {
            state.aborted = true;
            if (state.xhr) state.xhr.abort();
        }
    };
}

// Language of a text from its script, for "Auto". Only scripts that belong to one language are
// told apart (Thai, Japanese, Korean, Greek, ...); Latin text can't be (English, Estonian, Finnish,
// ...) and Cyrillic and Han only guess the commonest language, so those fall back to the OCR language.
var SCRIPTS = [
    { code: "th", re: /[\u0E00-\u0E7F]/g },
    { code: "lo", re: /[\u0E80-\u0EFF]/g },
    { code: "ja", re: /[\u3040-\u30FF]/g },
    { code: "ko", re: /[\u1100-\u11FF\uAC00-\uD7AF]/g },
    { code: "zh-Hans", re: /[\u4E00-\u9FFF]/g },
    { code: "el", re: /[\u0370-\u03FF]/g },
    { code: "he", re: /[\u0590-\u05FF]/g },
    { code: "ar", re: /[\u0600-\u06FF]/g },
    { code: "hi", re: /[\u0900-\u097F]/g },
    { code: "bn", re: /[\u0980-\u09FF]/g },
    { code: "my", re: /[\u1000-\u109F]/g },
    { code: "km", re: /[\u1780-\u17FF]/g },
    { code: "ru", re: /[\u0400-\u04FF]/g }
];

function detectSourceCode(text) {
    var latin = (text.match(/[A-Za-z\u00C0-\u024F]/g) || []).length;
    var counts = {};
    var total = latin;
    for (var i = 0; i < SCRIPTS.length; i++) {
        var n = (text.match(SCRIPTS[i].re) || []).length;
        counts[SCRIPTS[i].code] = n;
        total += n;
    }
    if (total === 0) return "";
    if (counts["ja"] > 0) return "ja"; // kana only occurs in Japanese; the Han characters then belong to it too
    var best = "";
    var bestCount = 0;
    for (var code in counts) {
        if (counts[code] > bestCount) {
            best = code;
            bestCount = counts[code];
        }
    }
    return bestCount * 10 >= total * 3 ? best : "";
}
