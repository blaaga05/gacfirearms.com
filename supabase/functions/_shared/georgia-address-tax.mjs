import { georgiaSalesTaxRate, GEORGIA_RATE_PERIOD } from './georgia-sales-tax.mjs';

const CENSUS_GEOCODER = 'https://geocoding.geo.census.gov/geocoder/geographies/address';
const ATLANTA_ZONE_LAYERS = [
  ['https://services5.arcgis.com/5RxyIIJ9boPdptdo/ArcGIS/rest/services/Gulch_Enterprise_Zone/FeatureServer/6/query', 'Centennial Yards'],
  ['https://services5.arcgis.com/5RxyIIJ9boPdptdo/ArcGIS/rest/services/Downtown_Enterprise_Zone/FeatureServer/5/query', 'South Downtown']
];

const normalize = value => String(value || '').trim().toLocaleLowerCase('en-US').replace(/\s+/g, ' ');
const countyName = geography => {
  const value = geography?.BASENAME || geography?.NAME || '';
  return String(value).replace(/\s+County(?:,.*)?$/i, '').trim();
};
const placeName = geography => {
  const value = geography?.BASENAME || geography?.NAME || '';
  return String(value).replace(/\s+(?:city|town|village|borough|municipality)(?:,.*)?$/i, '').trim();
};

async function censusGeographies(address, fetcher) {
  const url = new URL(CENSUS_GEOCODER);
  url.search = new URLSearchParams({
    street: address.address1,
    city: address.city,
    state: address.state,
    zip: address.postal_code.slice(0, 5),
    benchmark: 'Public_AR_Current',
    vintage: 'Current_Current',
    format: 'json'
  });
  const response = await fetcher(url, { signal: AbortSignal.timeout(10000), headers: { Accept: 'application/json' } });
  if (!response.ok) throw Error('The delivery address could not be verified. Check the street, city, state, and ZIP code.');
  const data = await response.json();
  const match = data?.result?.addressMatches?.[0];
  const geographies = match?.geographies;
  const states = geographies?.States || [];
  const counties = geographies?.Counties || [];
  if (!match || !geographies || !states.some(row => row.STUSAB === 'GA' || normalize(row.NAME).startsWith('georgia')) || !counties.length) {
    throw Error('We could not verify the county for this Georgia delivery address. Check the address and try again.');
  }
  const coordinates = match.coordinates;
  if (!Number.isFinite(coordinates?.x) || !Number.isFinite(coordinates?.y)) throw Error('We could not verify the tax area for this address. Check the address and try again.');
  return {
    county: countyName(counties[0]),
    place: placeName((geographies['Incorporated Places'] || [])[0]),
    longitude: coordinates.x,
    latitude: coordinates.y,
    matchedAddress: match.matchedAddress || null
  };
}

async function resolveAtlantaSpecialDistrict(location, fetcher) {
  for (const [endpoint, district] of ATLANTA_ZONE_LAYERS) {
    const url = new URL(endpoint);
    url.search = new URLSearchParams({
      where: '1=1',
      geometry: JSON.stringify({ x: location.longitude, y: location.latitude, spatialReference: { wkid: 4326 } }),
      geometryType: 'esriGeometryPoint',
      inSR: '4326',
      spatialRel: 'esriSpatialRelIntersects',
      returnCountOnly: 'true',
      f: 'json'
    });
    const response = await fetcher(url, { signal: AbortSignal.timeout(8000), headers: { Accept: 'application/json' } });
    if (!response.ok) throw Error('The Atlanta tax district could not be verified. Please check the address and try again.');
    const data = await response.json();
    if (data?.error || !Number.isInteger(data?.count)) throw Error('The Atlanta tax district could not be verified. Please check the address and try again.');
    if (data.count > 0) return district;
  }
  return null;
}

export async function resolveGeorgiaAddressTax(address, fetcher = fetch) {
  const location = await censusGeographies(address, fetcher);
  let district = 'county';
  const county = normalize(location.county);
  const place = normalize(location.place);
  if (county === 'fulton' || county === 'dekalb' || county === 'clayton') {
    if (county === 'fulton' && place === 'atlanta') {
      district = await resolveAtlantaSpecialDistrict(location, fetcher) || 'Atlanta';
    } else if (county === 'dekalb' && place === 'atlanta') {
      district = 'Atlanta';
    } else if (place === 'college park') {
      district = county === 'fulton' ? 'College Park (Fulton)' : county === 'clayton' ? 'College Park (Clayton)' : 'county';
    } else if (county === 'fulton' && (place === 'hapeville' || place === 'east point')) {
      district = location.place;
    }
  }
  const tax = georgiaSalesTaxRate({ country: 'US', state: 'GA', county: location.county, district });
  return {
    county: location.county,
    district,
    rate_bps: tax.rateBps,
    jurisdiction: tax.jurisdiction,
    matched_address: location.matchedAddress,
    tax_effective_from: GEORGIA_RATE_PERIOD.effectiveFrom,
    tax_effective_through: GEORGIA_RATE_PERIOD.effectiveThrough,
    tax_rate_source: 'Georgia DOR General Rate Chart'
  };
}

export { censusGeographies, resolveAtlantaSpecialDistrict };
