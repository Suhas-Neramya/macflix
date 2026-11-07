const vm = require('node:vm');
const fs = require('node:fs');
const assert = require('node:assert/strict');
const source = fs.readFileSync(require('node:path').join(__dirname,'../Resources/MultichannelAudio.js'),'utf8');
function run(code,host='www.netflix.com') {
 const context=vm.createContext({location:{hostname:host}});
 vm.runInContext('window=globalThis',context);
 vm.runInContext(source,context);
 return vm.runInContext(code,context);
}
const original={request:{profiles:['heaac-2-dash','hevc-main10-L40-dash-cenc']},password:'test-only-password',auth:{cookie:'test-only-token'}};
const patched=JSON.parse(run(`JSON.stringify(${JSON.stringify(original)})`));
assert.deepEqual(patched.request.profiles,[...original.request.profiles,'ddplus-2.0-dash','ddplus-5.1-dash','ddplus-5.1hq-dash','ddplus-atmos-dash']);
assert.equal(patched.password,original.password);assert.deepEqual(patched.auth,original.auth);
assert.equal(run(`const obj=${JSON.stringify(original)}; JSON.stringify(obj); obj.request.profiles.length`),2);
assert.equal(run(`JSON.stringify({profiles:['vp9-profile0-L30-dash-cenc']})`),' {"profiles":["vp9-profile0-L30-dash-cenc"]}'.trim());
assert.equal(run(`JSON.stringify({password:'test-only-password'})`),'{"password":"test-only-password"}');
assert.equal(run(`JSON.stringify({profiles:['heaac-2-dash']},['profiles'])`),'{"profiles":["heaac-2-dash"]}');
assert.equal(run(`JSON.stringify({profiles:['heaac-2-dash']},(k,v)=>v)`),'{"profiles":["heaac-2-dash"]}');
assert.equal(run(`JSON.stringify({profiles:['heaac-2-dash']})`,'notnetflix.com'),'{"profiles":["heaac-2-dash"]}');
assert.equal(run(`JSON.stringify({profiles:['heaac-2-dash',2]})`),'{"profiles":["heaac-2-dash",2]}');
assert.equal(run(`let o={};o.o=o;try{JSON.stringify(o);'failed'}catch(e){e.name}`),'TypeError');
assert.equal(run(`JSON.stringify(undefined)`),undefined);
assert.equal(run(`JSON.stringify({profiles:['heaac-2-dash']}); __netflixNativeMultichannelStatus.changedSerializations`),1);
assert.equal(run(`JSON.stringify({profiles:['heaac-2-dash','ddplus-2.0-dash','ddplus-5.1-dash','ddplus-5.1hq-dash','ddplus-atmos-dash']}); __netflixNativeMultichannelStatus.changedSerializations`),0);
assert.equal(run(`JSON.stringify({password:'test-only-password'}); __netflixNativeMultichannelStatus.changedSerializations`),0);
console.log('Passed: audio-only additions, video profiles, credentials, caller object, replacers, hostname restriction, invalid profiles, standard errors, and request counts.');
