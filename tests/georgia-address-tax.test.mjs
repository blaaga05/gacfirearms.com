import test from 'node:test';
import assert from 'node:assert/strict';
import {resolveGeorgiaAddressTax} from '../supabase/functions/_shared/georgia-address-tax.mjs';

const address={address1:'123 Test Street',city:'Testville',state:'GA',postal_code:'31047'};
const json=value=>new Response(JSON.stringify(value));
const census=(county,place='')=>json({result:{addressMatches:[{matchedAddress:'123 TEST STREET, TESTVILLE, GA, 31047',coordinates:{x:-83.5,y:32.5},geographies:{States:[{STUSAB:'GA',NAME:'Georgia'}],Counties:[{BASENAME:county,NAME:county+' County, Georgia'}],'Incorporated Places':place?[{BASENAME:place,NAME:place+' city, Georgia'}]:[]}}]}});
const arc=count=>json({count});

test('Georgia address geocodes to county and DOR rate without trusting submitted county fields',async()=>{
 let calls=0;const result=await resolveGeorgiaAddressTax({...address,county:'Fulton'},async(url)=>{calls++;assert.match(String(url),/^https:\/\/geocoding\.geo\.census\.gov/);return census('Houston')});
 assert.equal(calls,1);assert.equal(result.county,'Houston');assert.equal(result.district,'county');assert.equal(result.rate_bps,800);assert.equal(result.jurisdiction,'Houston');
});

test('known incorporated Georgia cities resolve to the appropriate DOR city rate',async()=>{
 const result=await resolveGeorgiaAddressTax(address,async()=>census('Fulton','Hapeville'));
 assert.equal(result.rate_bps,875);assert.equal(result.jurisdiction,'Hapeville');
});

test('Atlanta point is checked against official Gulch and Downtown Enterprise Zone boundaries',async()=>{
 const visited=[];const result=await resolveGeorgiaAddressTax(address,async(url)=>{const target=String(url);if(target.startsWith('https://geocoding.geo.census.gov'))return census('Fulton','Atlanta');visited.push(target);return arc(target.includes('Gulch_Enterprise_Zone')?1:0)});
 assert.equal(visited.length,1);assert.match(visited[0],/Gulch_Enterprise_Zone/);assert.equal(result.rate_bps,390);assert.equal(result.jurisdiction,'Centennial Yards');
});

test('ordinary Atlanta address uses Atlanta rate only after both special-zone checks are clear',async()=>{
 let checks=0;const result=await resolveGeorgiaAddressTax(address,async url=>{if(String(url).startsWith('https://geocoding.geo.census.gov'))return census('Fulton','Atlanta');checks++;return arc(0)});
 assert.equal(checks,2);assert.equal(result.rate_bps,890);assert.equal(result.jurisdiction,'Atlanta');
});

test('tax checkout fails closed when address or special district cannot be verified',async()=>{
 await assert.rejects(()=>resolveGeorgiaAddressTax(address,async()=>json({result:{addressMatches:[]}})),/could not verify the county/i);
 await assert.rejects(()=>resolveGeorgiaAddressTax(address,async url=>String(url).startsWith('https://geocoding.geo.census.gov')?census('Fulton','Atlanta'):json({error:{message:'unavailable'}})),/Atlanta tax district could not be verified/i);
});
