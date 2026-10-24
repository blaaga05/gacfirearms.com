import test from 'node:test';
import assert from 'node:assert/strict';
import {GEORGIA_COUNTIES, GEORGIA_RATE_PERIOD, georgiaSalesTaxRate, georgiaTaxOptions} from '../georgia-sales-tax.mjs';

test('Georgia county table matches the Q4 2026 DOR chart coverage',()=>{
 assert.equal(GEORGIA_COUNTIES.length,159);
 assert.equal(new Set(GEORGIA_COUNTIES.map(x=>x.toLowerCase())).size,159);
 assert.equal(GEORGIA_RATE_PERIOD.effectiveFrom,'2026-10-01');
 assert.equal(GEORGIA_RATE_PERIOD.effectiveThrough,'2026-12-31');
});
test('Georgia delivery tax uses the destination county rate',()=>{
 assert.deepEqual(georgiaSalesTaxRate({state:'GA',county:'Houston'}),{rateBps:800,jurisdiction:'Houston'});
 assert.deepEqual(georgiaSalesTaxRate({state:'GA',county:'Cobb'}),{rateBps:600,jurisdiction:'Cobb'});
 assert.deepEqual(georgiaSalesTaxRate({state:'GA',county:'Fulton'}),{rateBps:775,jurisdiction:'Fulton'});
});
test('special city districts use the DOR chart rate',()=>{
 assert.equal(georgiaSalesTaxRate({state:'GA',county:'Fulton',district:'Atlanta'}).rateBps,890);
 assert.equal(georgiaSalesTaxRate({state:'GA',county:'Fulton',district:'Hapeville'}).rateBps,875);
 assert.equal(georgiaSalesTaxRate({state:'GA',county:'Fulton',district:'Centennial Yards'}).rateBps,390);
 assert.equal(georgiaSalesTaxRate({state:'GA',county:'DeKalb',district:'Atlanta'}).rateBps,890);
 assert.equal(georgiaSalesTaxRate({state:'GA',county:'Clayton',district:'College Park (Clayton)'}).rateBps,900);
 assert.deepEqual(georgiaTaxOptions('Houston'),[]);
});
test('out-of-state delivery collects no tax for GAC and unsupported GA counties fail closed',()=>{
 assert.deepEqual(georgiaSalesTaxRate({state:'FL',county:'Miami-Dade'}),{rateBps:0,jurisdiction:null});
 assert.throws(()=>georgiaSalesTaxRate({state:'GA',county:''}),/county/);
 assert.throws(()=>georgiaSalesTaxRate({state:'GA',county:'Fulton',district:'Atlanta',country:'CA'}),/United States/);
 assert.throws(()=>georgiaSalesTaxRate({state:'GA',county:'Houston',asOf:'2027-01-01'}),/need an update/);
 assert.equal(georgiaSalesTaxRate({state:'FL',county:'Miami-Dade',asOf:'2027-01-01'}).rateBps,0);
});
