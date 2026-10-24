// Georgia DOR General Rate Chart, effective October 1–December 31, 2026.
// Refresh this table when DOR publishes the next quarterly chart.
export const GEORGIA_RATE_PERIOD = Object.freeze({
  effectiveFrom: '2026-10-01',
  effectiveThrough: '2026-12-31',
  source: 'https://dor.georgia.gov/document/document/general-rate-chart-effective-october-1-2026/download'
});

const COUNTY_RATES = `
Appling|8
Atkinson|8
Bacon|8
Baker|8
Baldwin|8
Banks|9
Barrow|8
Bartow|7
Ben Hill|8
Berrien|9
Bibb|8
Bleckley|8
Brantley|8
Brooks|8
Bryan|9
Bulloch|9
Burke|7
Butts|8
Calhoun|8
Camden|7
Candler|9
Carroll|7
Catoosa|7
Charlton|8
Chatham|7
Chattahoochee|9
Chattooga|9
Cherokee|7
Clarke|8
Clay|9
Clayton|8
Clinch|8
Cobb|6
Coffee|8
Colquitt|9
Columbia|8
Cook|9
Coweta|8
Crawford|8
Crisp|8
Dade|7
Dawson|8
Decatur|9
DeKalb|8
Dodge|8
Dooly|8
Dougherty|9
Douglas|7
Early|8
Echols|8
Effingham|8
Elbert|9
Emanuel|9
Evans|9
Fannin|7
Fayette|7
Floyd|7
Forsyth|7
Franklin|7
Fulton|7.75
Gilmer|7
Glascock|8
Glynn|7
Gordon|8
Grady|8
Greene|8
Gwinnett|6
Habersham|7
Hall|7
Hancock|8
Haralson|8
Harris|8
Hart|7
Heard|8
Henry|8
Houston|8
Irwin|8
Jackson|8
Jasper|8
Jeff Davis|8
Jefferson|9
Jenkins|9
Johnson|8
Jones|7
Lamar|9
Lanier|8
Laurens|8
Lee|8
Liberty|9
Lincoln|9
Long|9
Lowndes|8
Lumpkin|8
Macon|8
Madison|7
Marion|8
McDuffie|9
McIntosh|8
Meriwether|8
Miller|9
Mitchell|8
Monroe|9
Montgomery|8
Morgan|8
Murray|9
Muscogee|9
Newton|7
Oconee|8
Oglethorpe|9
Paulding|7
Peach|9
Pickens|7
Pierce|8
Pike|7
Polk|7
Pulaski|8
Putnam|8
Quitman|8
Rabun|8
Randolph|8
Richmond|9
Rockdale|7
Schley|9
Screven|8
Seminole|8
Spalding|7
Stephens|7
Stewart|8
Sumter|8
Talbot|8
Taliaferro|8
Tattnall|9
Taylor|8
Telfair|8
Terrell|8
Thomas|8
Tift|8
Toombs|8
Towns|7
Treutlen|8
Troup|7
Turner|9
Twiggs|8
Union|7
Upson|9
Walker|8
Walton|7
Ware|8
Warren|9
Washington|9
Wayne|8
Webster|8
Wheeler|8
White|8
Whitfield|7
Wilcox|9
Wilkes|9
Wilkinson|8
Worth|8`.trim();

const normalize = value => String(value || '').trim().toLocaleLowerCase('en-US').replace(/\s+/g, ' ');
const rates = new Map(COUNTY_RATES.split('\n').map(row => {
  const [county, percent] = row.split('|');
  return [normalize(county), Math.round(Number(percent) * 100)];
}));

const special = Object.freeze({
  fulton: Object.freeze({
    county: 775,
    Atlanta: 890,
    Hapeville: 875,
    'College Park (Fulton)': 875,
    'East Point': 875,
    'Centennial Yards': 390,
    'South Downtown': 390
  }),
  dekalb: Object.freeze({ county: 800, Atlanta: 890 }),
  clayton: Object.freeze({ county: 800, 'College Park (Clayton)': 900 })
});

export const GEORGIA_COUNTIES = Object.freeze(COUNTY_RATES.split('\n').map(row => row.split('|')[0]));
export function georgiaTaxOptions(county) {
  const entries = special[normalize(county)];
  return entries ? Object.keys(entries) : [];
}

export function georgiaSalesTaxRate({ country = 'US', state, county, district = 'county', asOf = new Date().toISOString().slice(0, 10) } = {}) {
  if (String(country).toUpperCase() !== 'US') throw new Error('GAC merchandise checkout currently ships within the United States.');
  if (String(state || '').trim().toUpperCase() !== 'GA') return { rateBps: 0, jurisdiction: null };
  if (asOf < GEORGIA_RATE_PERIOD.effectiveFrom || asOf > GEORGIA_RATE_PERIOD.effectiveThrough) throw new Error('Georgia sales tax rates need an update before checkout can continue.');
  const key = normalize(county);
  if (!rates.has(key)) throw new Error('Choose the Georgia county where the order will be delivered.');
  const options = special[key];
  const choice = district || 'county';
  if (options) {
    const rate = choice === 'county' ? options.county : options[choice];
    if (!Number.isInteger(rate)) throw new Error('Choose a valid local tax area for this delivery address.');
    return { rateBps: rate, jurisdiction: choice === 'county' ? county : choice };
  }
  if (choice !== 'county') throw new Error('The selected local tax area does not match this county.');
  return { rateBps: rates.get(key), jurisdiction: county };
}
