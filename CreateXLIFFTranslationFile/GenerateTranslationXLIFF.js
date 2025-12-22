// How to run:
//   node ScriptPath BCProjectPath
//   node "GenerateTranslationXLIFF.js" "C:\Documents\AL\ALProject1"
//   node "C:\Users\Brian Carrillo\Downloads\AL-Translation\GenerateTranslationXLIFF.js" "C:\Users\Brian Carrillo\Documents\Desarrollo BC GitHub\Capitole\Capitole-FAES"

"use strict";
Object.defineProperty(exports, "__esModule", { value: true });
const fs = require("fs");
const xml2js = require("xml2js");
const OLD_LANGUAGE_CODES = ["ESP", "SVE", "RUS", "NLD", "NLB", "NOR", "ITA", "ITS", "ISL", "FRA", "FRS", "FRC", "FRB", "FIN", "ESM", "ENU", "ENZ", "ENG", "ENC", "ENA", "DEU", "DES", "DEA", "DAN", "CSY", "PTG"];
const NEW_LANGUAGE_CODES = ["es-ES", "sv-SE", "ru-RU", "nl-NL", "nl-BE", "nb-NO", "it-IT", "it-CH", "is-IS", "fr-FR", "fr-CH", "fr-CA", "fr-BE", "fi-FI", "es-MX", "en-US", "en-NZ", "en-GB", "en-CA", "en-AU", "de-DE", "de-CH", "de-AT", "da-DK", "cs-CZ", "pt-PT"];
const PROJECT_PATH = process.argv[2];
let appJSON;
let oldLanguageCodes = [];
let newLanguageCodes = [];
class XliffFileMgt {
    static GenerateXliffFiles() {
        if (PROJECT_PATH === undefined) {
            console.log('Invalid parameter PROJECT_PATH');
            return;
        }
        console.log(`Generating Xliff files...`);
        //Getting the app.json file
        appJSON = getAppJSON();
        if (!appJSON) {
            return;
        }
        const XLIFF_FILE_PATH = `${PROJECT_PATH}\\Translations\\${appJSON.name}.g.xlf`;
        //Reading the XLIFF file
        fs.readFile(XLIFF_FILE_PATH, onXliffFileRead);
    }
}
exports.XliffFileMgt = XliffFileMgt;

XliffFileMgt.GenerateXliffFiles();

/**
 * Event triggered when XLIFF file is read
 * @param err Error data (if there is an error)
 * @param data Read data
 */
function onXliffFileRead(err, data) {
    if (err) {
        return;
    }
    //Parsing the file content and converting it from XML to JSON
    let parser = new xml2js.Parser();
    parser.parseString(data, onStringParsed);
}
/**
 * Event triggered when XLIFF read data is parsed and transformed to JSON
 * @param err Error data (if there is an error)
 * @param result Result in JSON format
 */
function onStringParsed(err, result) {
    if (err) return;

    oldLanguageCodes = getTargetLanguages(result);
    console.log('Detected languages (OLD):', oldLanguageCodes);
    oldLanguageCodes = oldLanguageCodes
    .map(l => l.replace('%', '').trim().toUpperCase())
    .filter(l => OLD_LANGUAGE_CODES.includes(l));
    newLanguageCodes = transformLanguageCodesOldToNew(oldLanguageCodes);

    // UN ARCHIVO POR IDIOMA
    for (let fileIndex = 0; fileIndex < newLanguageCodes.length; fileIndex++) {

        const currentOldLanguageCode = oldLanguageCodes[fileIndex]
            .replace('%', '')
            .trim()
            .toUpperCase();

        const currentNewLanguageCode = newLanguageCodes[fileIndex];

        // Clonar XML base
        let clonedResult = JSON.parse(JSON.stringify(result));

        // Set target language
        clonedResult['xliff']['file'][0]['$']['target-language'] =
            currentNewLanguageCode;

        let transUnits =
            clonedResult['xliff']['file'][0]['body'][0]['group'][0]['trans-unit'];

        // Limpiar targets antes de empezar
        for (const unit of transUnits) {
            delete unit['target'];
        }
        // Procesar trans-units
        for (let j = 0; j < transUnits.length; j++) {
            let hasLanguage = false;
            if (!transUnits[j]['note']) {
                transUnits.splice(j, 1);
                j--;
                continue;
            }
            for (const note of transUnits[j]['note']) {
                if (
                    note['$']?.['from'] === 'Developer' &&
                    typeof note['_'] === 'string'
                ) {
                    const translations = note['_']
                        .split(/,(?=(?:[^"]*"[^"]*")*[^"]*$)/);

                    for (const translation of translations) {
                        const [langRaw, valueRaw] = translation.split('=');
                        if (!langRaw || !valueRaw) continue;

                        const lang = langRaw
                            .replace('%', '')
                            .trim()
                            .toUpperCase();

                        let value = valueRaw.trim().replace(/^"(.*)"$/, '$1');

                        if (lang === currentOldLanguageCode) {
                            transUnits[j]['target'] = value;
                            hasLanguage = true;
                            break; // idioma encontrado
                        }
                    }
                }
                if (hasLanguage) break;
            }
            // eliminar solo si NO existe traducción para este idioma
            if (!hasLanguage) {
                transUnits.splice(j, 1);
                j--;
            }
        }
        // Guardar archivo
        const builder = new (require('xml2js')).Builder();
        const xml = builder.buildObject(clonedResult);

        const fs = require('fs');
        const PROJECT_PATH = process.argv[2];
        const appJSON = getAppJSON();

        fs.writeFileSync(
            `${PROJECT_PATH}\\Translations\\${appJSON.name}.${currentNewLanguageCode}.g.xlf`,
            xml,
            'utf8'
        );

        console.log(
            `Created file: ${appJSON.name}.${currentNewLanguageCode}.g.xlf`
        );
    }
}


/**
 * Event triggered when new XLIFF file is written
 * @param err Error data (if there is an error)
 */
function onFileWritten(err) {
    if (err) {
        return;
    }
}
/**
 * Reads the app.json file and returns it or returns null if there is an error
 */
function getAppJSON() {
    let appJSON;
    try {
        appJSON = JSON.parse(fs.readFileSync(`${PROJECT_PATH}\\app.json`, 'utf8'));
    }
    catch (err) {
        return null;
    }
    return appJSON;
}
/**
 * Returns the languages found in XLIFF notes
 */
function getTargetLanguages(jsonObj) {
    let transUnits = jsonObj['xliff']['file'][0]['body'][0]['group'][0]['trans-unit'];
    let languages = [];
    for (const transUnit of transUnits) {
        for (const note of transUnit['note']) {
            //If the note is a translations comment and it has a translation
            if (note['$']['from'] === 'Developer' && typeof note['_'] !== 'undefined') {
                //let translations = note['_'].toString().split(',');
                //Split between not quoted commas
                let translations = note['_'].toString().split(/(,)(?=(?:[^"]|"[^"]*")*$)/);
                let noteLanguages = [];
                //Get the languages found in the note
                for (const translation of translations) {
                    if (translation != ',') {
                        noteLanguages.push(translation.split('=')[0]);
                    }
                }
                //Save note language if it was not found yet
                for (const noteLanguage of noteLanguages) {
                    if (languages.indexOf(noteLanguage) === -1)
                        languages.push(noteLanguage);
                }
            }
        }
    }
    return languages;
}
/**
 * Transforms the language codes from old to new format and returns it
 */
function transformLanguageCodesOldToNew(languageCodes) {
    let newLanguages = [];
    for (let language of languageCodes) {
        const languageCodeIndex = OLD_LANGUAGE_CODES.indexOf(language);
        if (languageCodeIndex > -1) {
            newLanguages.push(NEW_LANGUAGE_CODES[languageCodeIndex]);
        }
    }
    return newLanguages;
}
//# sourceMappingURL=XliffFileMgt.js.map