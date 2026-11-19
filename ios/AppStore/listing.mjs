// node ios/AppStore/listing.mjs [--dry-run]
// Puts listing.json and the answers below into App Store Connect for the version in
// "Prepare for Submission": name, subtitle, categories, URLs, description, keywords, copyright,
// content rights, age rating, price (free), availability and App Review details. Idempotent.
// Screenshots, the preview and the privacy label are separate (see README.md).
import { readFileSync } from 'node:fs';
import { asc } from './asc.mjs';

const listing = JSON.parse(readFileSync(new URL('./listing.json', import.meta.url), 'utf8'));
const notes = readFileSync(new URL('./review-notes.txt', import.meta.url), 'utf8').trim();
const dryRun = process.argv.includes('--dry-run');

async function call(method, path, body) {
  if (dryRun && method !== 'GET') return console.log('would', method, path), { json: {} };
  const r = await asc(method, path, body);
  if (r.status >= 400) throw new Error(`${method} ${path}: ${r.status} ${JSON.stringify(r.json?.errors)}`);
  return r;
}
const one = async (path) => (await call('GET', path)).json.data;

// Age rating: nothing in the app needs a descriptor (see README.md, Age rating).
const ageRating = {
  alcoholTobaccoOrDrugUseOrReferences: 'NONE', contests: 'NONE', gamblingSimulated: 'NONE',
  gunsOrOtherWeapons: 'NONE', horrorOrFearThemes: 'NONE', matureOrSuggestiveThemes: 'NONE',
  medicalOrTreatmentInformation: 'NONE', profanityOrCrudeHumor: 'NONE',
  sexualContentGraphicAndNudity: 'NONE', sexualContentOrNudity: 'NONE',
  violenceCartoonOrFantasy: 'NONE', violenceRealistic: 'NONE',
  violenceRealisticProlongedGraphicOrSadistic: 'NONE',
  advertising: false, ageAssurance: false, gambling: false, healthOrWellnessTopics: false,
  lootBox: false, messagingAndChat: false, parentalControls: false, socialMedia: false,
  unrestrictedWebAccess: false, userGeneratedContent: false,
};

const app = listing.app;
const versions = await one(`/v1/apps/${app}/appStoreVersions?filter[appStoreState]=PREPARE_FOR_SUBMISSION&filter[platform]=IOS`);
if (versions.length !== 1) throw new Error('expected one iOS version in Prepare for Submission');
const version = versions[0];
const info = (await one(`/v1/apps/${app}/appInfos`)).find((i) => i.attributes.state !== 'READY_FOR_DISTRIBUTION');

await call('PATCH', `/v1/apps/${app}`, { data: { type: 'apps', id: app, attributes: { contentRightsDeclaration: 'DOES_NOT_USE_THIRD_PARTY_CONTENT' } } });
await call('PATCH', `/v1/appInfos/${info.id}`, { data: { type: 'appInfos', id: info.id, relationships: {
  primaryCategory: { data: { type: 'appCategories', id: listing.primaryCategory } },
  secondaryCategory: { data: { type: 'appCategories', id: listing.secondaryCategory } },
} } });
const infoLoc = (await one(`/v1/appInfos/${info.id}/appInfoLocalizations`)).find((l) => l.attributes.locale === 'en-US');
await call('PATCH', `/v1/appInfoLocalizations/${infoLoc.id}`, { data: { type: 'appInfoLocalizations', id: infoLoc.id, attributes: {
  name: listing.name, subtitle: listing.subtitle, privacyPolicyUrl: listing.privacyPolicyUrl,
} } });
const age = await one(`/v1/appInfos/${info.id}/ageRatingDeclaration`);
await call('PATCH', `/v1/ageRatingDeclarations/${age.id}`, { data: { type: 'ageRatingDeclarations', id: age.id, attributes: ageRating } });

await call('PATCH', `/v1/appStoreVersions/${version.id}`, { data: { type: 'appStoreVersions', id: version.id, attributes: {
  copyright: listing.copyright, releaseType: 'MANUAL',
} } });
const loc = (await one(`/v1/appStoreVersions/${version.id}/appStoreVersionLocalizations`)).find((l) => l.attributes.locale === 'en-US');
await call('PATCH', `/v1/appStoreVersionLocalizations/${loc.id}`, { data: { type: 'appStoreVersionLocalizations', id: loc.id, attributes: {
  description: listing.description, keywords: listing.keywords, promotionalText: listing.promotionalText,
  supportUrl: listing.supportUrl, marketingUrl: listing.marketingUrl,
} } });

// Free, in the listed territories only (not the EU, so no Digital Services Act trader listing).
const free = (await one(`/v1/apps/${app}/appPricePoints?filter[territory]=USA&limit=1`))[0];
await call('POST', '/v1/appPriceSchedules', {
  data: { type: 'appPriceSchedules', relationships: {
    app: { data: { type: 'apps', id: app } },
    baseTerritory: { data: { type: 'territories', id: 'USA' } },
    manualPrices: { data: [{ type: 'appPrices', id: '${price}' }] },
  } },
  included: [{ type: 'appPrices', id: '${price}', attributes: { startDate: null },
    relationships: { appPricePoint: { data: { type: 'appPricePoints', id: free.id } } } }],
});
const existing = await asc('GET', `/v1/apps/${app}/appAvailabilityV2`);
if (existing.status === 404) {
  // Apple wants every territory in the request, each marked available or not.
  const all = (await one('/v1/territories?limit=200')).map((t) => t.id);
  await call('POST', '/v2/appAvailabilities', {
    data: { type: 'appAvailabilities', attributes: { availableInNewTerritories: false }, relationships: {
      app: { data: { type: 'apps', id: app } },
      territoryAvailabilities: { data: all.map((t) => ({ type: 'territoryAvailabilities', id: `\${${t}}` })) },
    } },
    included: all.map((t) => ({ type: 'territoryAvailabilities', id: `\${${t}}`,
      attributes: { available: listing.territories.includes(t), releaseDate: null, preOrderEnabled: false },
      relationships: { territory: { data: { type: 'territories', id: t } } } })),
  });
}

// App Review: the contact (kept out of this public repo) is copied from the newest version of
// the team's other app; sign-in needs no demo account.
async function reviewContact() {
  for (const v of await one(`/v1/apps/${listing.reviewContactFromApp}/appStoreVersions?limit=5`)) {
    const a = (await asc('GET', `/v1/appStoreVersions/${v.id}/appStoreReviewDetail`)).json?.data?.attributes;
    if (a?.contactPhone) return { contactFirstName: a.contactFirstName, contactLastName: a.contactLastName,
      contactEmail: a.contactEmail, contactPhone: a.contactPhone };
  }
  throw new Error('no App Review contact to copy');
}
const review = await asc('GET', `/v1/appStoreVersions/${version.id}/appStoreReviewDetail`);
const reviewAttributes = { ...(await reviewContact()), demoAccountRequired: false, notes };
if (review.json?.data) {
  await call('PATCH', `/v1/appStoreReviewDetails/${review.json.data.id}`, { data: { type: 'appStoreReviewDetails', id: review.json.data.id, attributes: reviewAttributes } });
} else {
  await call('POST', '/v1/appStoreReviewDetails', { data: { type: 'appStoreReviewDetails', attributes: reviewAttributes,
    relationships: { appStoreVersion: { data: { type: 'appStoreVersions', id: version.id } } } } });
}
console.log(`listing applied to ${listing.name} ${version.attributes.versionString}`);
