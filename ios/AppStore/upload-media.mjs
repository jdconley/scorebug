// node ios/AppStore/upload-media.mjs [dir]
// Uploads the store screenshots and app preview in <dir> (default ios/AppStore/screenshots and
// ios/AppStore/preview) to the version in Prepare for Submission, replacing what's there:
//   iphone-N.jpg -> iPhone 6.3" (APP_IPHONE_61)      ipad-N.jpg -> iPad 13" (APP_IPAD_PRO_3GEN_129)
//   watch-N.png  -> Apple Watch Ultra (APP_WATCH_ULTRA)  preview/iphone-preview.mp4 -> IPHONE_61
import { createHash } from 'node:crypto';
import { existsSync, readFileSync, readdirSync } from 'node:fs';
import { basename, join } from 'node:path';
import { asc } from './asc.mjs';

const here = new URL('.', import.meta.url).pathname;
const shots = process.argv[2] ?? join(here, 'screenshots');
const preview = join(here, 'preview', 'iphone-preview.mp4');
const listing = JSON.parse(readFileSync(join(here, 'listing.json'), 'utf8'));

async function call(method, path, body) {
  const r = await asc(method, path, body);
  if (r.status >= 400) throw new Error(`${method} ${path}: ${r.status} ${JSON.stringify(r.json?.errors)}`);
  return r.json;
}

/** Reserve, upload the parts, then commit with the checksum; waits until Apple has processed it. */
async function upload(type, attributes, relationship, file) {
  const data = readFileSync(file);
  const created = await call('POST', `/v1/${type}`, { data: { type, attributes: { ...attributes,
    fileName: basename(file), fileSize: data.length }, relationships: relationship } });
  for (const op of created.data.attributes.uploadOperations) {
    const res = await fetch(op.url, { method: op.method, body: data.subarray(op.offset, op.offset + op.length),
      headers: Object.fromEntries(op.requestHeaders.map((h) => [h.name, h.value])) });
    if (!res.ok) throw new Error(`upload ${basename(file)}: ${res.status}`);
  }
  const md5 = createHash('md5').update(data).digest('hex');
  await call('PATCH', `/v1/${type}/${created.data.id}`, { data: { type, id: created.data.id,
    attributes: { uploaded: true, sourceFileChecksum: md5 } } });
  for (let i = 0; i < 60; i++) {
    const state = (await call('GET', `/v1/${type}/${created.data.id}`)).data.attributes.assetDeliveryState?.state;
    if (state === 'COMPLETE') return console.log(`  ${basename(file)}`);
    if (state === 'FAILED') throw new Error(`${basename(file)}: Apple couldn't process it`);
    await new Promise((r) => setTimeout(r, 5000));
  }
  console.log(`  ${basename(file)} (still processing)`);
}

const version = (await call('GET', `/v1/apps/${listing.app}/appStoreVersions?filter[appStoreState]=PREPARE_FOR_SUBMISSION&filter[platform]=IOS`)).data[0];
const loc = (await call('GET', `/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`)).data.find((l) => l.attributes.locale === 'en-US');

async function replaceSet(kind, displayType, files) {
  if (files.length === 0) return;
  const [setType, setKey, itemType] = kind === 'shots'
    ? ['appScreenshotSets', 'screenshotDisplayType', 'appScreenshots']
    : ['appPreviewSets', 'previewType', 'appPreviews'];
  const sets = (await call('GET', `/v1/appStoreVersionLocalizations/${loc.id}/${setType}`)).data;
  let set = sets.find((s) => s.attributes[setKey] === displayType);
  if (set) {
    for (const item of (await call('GET', `/v1/${setType}/${set.id}/${itemType}`)).data)
      await call('DELETE', `/v1/${itemType}/${item.id}`);
  } else {
    set = (await call('POST', `/v1/${setType}`, { data: { type: setType, attributes: { [setKey]: displayType },
      relationships: { appStoreVersionLocalization: { data: { type: 'appStoreVersionLocalizations', id: loc.id } } } } })).data;
  }
  console.log(displayType);
  const relationship = { [kind === 'shots' ? 'appScreenshotSet' : 'appPreviewSet']: { data: { type: setType, id: set.id } } };
  for (const file of files)
    await upload(itemType, kind === 'shots' ? {} : { mimeType: 'video/mp4', previewFrameTimeCode: '00:00:05:00' }, relationship, file);
}

const list = (prefix, ext) => readdirSync(shots).filter((f) => f.startsWith(`${prefix}-`) && f.endsWith(ext))
  .sort((a, b) => parseInt(a.slice(prefix.length + 1)) - parseInt(b.slice(prefix.length + 1))).map((f) => join(shots, f));
await replaceSet('shots', 'APP_IPHONE_61', list('iphone', '.jpg'));
await replaceSet('shots', 'APP_IPAD_PRO_3GEN_129', list('ipad', '.jpg'));
await replaceSet('shots', 'APP_WATCH_ULTRA', list('watch', '.png'));
if (existsSync(preview)) await replaceSet('previews', 'IPHONE_61', [preview]);
