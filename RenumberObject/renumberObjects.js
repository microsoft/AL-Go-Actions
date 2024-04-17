const fs = require('fs-extra');
const path = require('path');
const glob = require('glob-promise');

// Leer los rangos de ID desde app.json
async function readAppJson(appJsonPath) {
  try {
    const data = await fs.readJson(appJsonPath);
    console.info("ID Ranges from app.json:", data.idRanges);
    return data.idRanges;
  } catch (error) {
    console.error("Error reading app.json:", error);
    throw error;
  }
}

// Encontrar todos los archivos .al en el proyecto
async function findALFiles(rootPath) {
  const pattern = path.join(rootPath, 'src', '**', '*.al').replace(/\\/g, '/');
  const files = await glob(pattern);
  console.log(`Found ${files.length} AL files.`);
  return files;
}

// Inicializar un objeto para rastrear el último ID usado para cada tipo de objeto
const lastUsedIds = {};

function getNewId(currentId, idRanges, objectType) {
  // Asegúrate de que estás trabajando con el objeto correcto dentro del arreglo
  const currentRange = idRanges[0];  // Aquí asumimos que quieres usar el primer rango disponible

  if (!lastUsedIds[objectType]) {
    lastUsedIds[objectType] = currentRange.from - 1;
  }

  if (lastUsedIds[objectType] < currentRange.to) {
    lastUsedIds[objectType]++;
    return lastUsedIds[objectType];
  }

  console.log(`No new ID assigned, returning original ID: ${currentId}`);
  return currentId;
}

// Reenumerar campos dentro de tableextension
function reenumerateFields(content, idRanges) {
  const fieldRegex = /field\(\s*(\d+);\s*"([^"]+)";\s*([\w\s\[\]\"']+)/g;
  let currentId = idRanges.from;
  console.log(`Starting reenumeration with ID range from ${idRanges.from} to ${idRanges.to}`);

  return content.replace(fieldRegex, (match, oldId, fieldName, fieldType) => {
    if (currentId <= idRanges.to) {
      console.log(`Changing field ID from ${oldId} to ${currentId} for field '${fieldName}' of type '${fieldType.trim()}'`);
      const result = `field(${currentId}; "${fieldName}"; ${fieldType.trim()}`;
      console.log(result);
      currentId++;
      return result;
    } else {
      console.log(`ID range exhausted, could not reenumerate field '${fieldName}' with old ID ${oldId}`);
    }
    return match;  // Return original match if ID could not be changed
  });
}

// Reenumerar un archivo AL
async function reenumerateALFile(filePath, idRanges) {
  console.log(`Processing file: ${filePath}`);
  let content = await fs.readFile(filePath, 'utf8');
  let modified = false;
  const objectRegex = /^(table|tableextension|page|pageextension|pagecustomization|codeunit|report|reportextension|query|profile|xmlport|enum|enumextension|controladdin|interface|permissionset|permissionsetextension)\s+(\d+)\s+"([^"]+)"(?:\s+extends\s+"([^"]+)")?/gm;
  
  let newContent = content.replace(objectRegex, (match, type, id, name, extendsName) => {
    console.log(`Attempting to match: ${match}`);
    const newId = getNewId(parseInt(id), idRanges, type.toLowerCase());
    if (newId !== parseInt(id)) {
      modified = true;
      if (extendsName) {
        console.log(`Changing ID and extending ${type} from ${id} to ${newId}, extends "${extendsName}"`);
        return `${type} ${newId} "${name}" extends "${extendsName}"`;
      } else {
        console.log(`Changing ID from ${id} to ${newId} for ${type} named "${name}"`);
        return `${type} ${newId} "${name}"`;

      }
    }
    return match;
  });

  // Luego aplicar cambios para TableExt, si corresponde
  if (path.basename(filePath).toLowerCase().includes('tableext')) {
    let fieldModifiedContent = reenumerateFields(newContent, idRanges[0]); // Usa newContent aquí
    if (fieldModifiedContent !== newContent) {
      modified = true;
      newContent = fieldModifiedContent; // Asegura actualizar newContent con los últimos cambios
    }
  }

  // Escribir de vuelta al archivo solo si hubo modificaciones
  if (modified) {
    await fs.writeFile(filePath, newContent, 'utf8');
    console.log(`File ${filePath} renumbered and saved.`);
  }
}

// Función principal que orquesta todo el proceso
async function main() {
  const rootPath = process.argv[2]; // Asegúrate de que esta es la ruta correcta
  const appJsonPath = path.join(rootPath, 'app.json');
  const idRanges = await readAppJson(appJsonPath); // Asume que idRanges tiene { from: 50400, to: 50449 }
  console.log("ID Ranges in MAIN:", idRanges);
  const files = await findALFiles(rootPath);
  for (const file of files) {
    await reenumerateALFile(file, idRanges);
  }
  console.log('All files have been processed.');
}

main().catch(console.error);