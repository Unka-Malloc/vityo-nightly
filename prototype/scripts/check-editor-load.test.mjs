import assert from 'node:assert/strict';
import fs from 'node:fs/promises';
import vm from 'node:vm';
import test from 'node:test';
const file=new URL('./check-editor-load.mjs', import.meta.url);
const original=await fs.readFile(file,'utf8');
const source=original.slice(original.indexOf('async function runSelfTest()'), original.indexOf('\nrunSelfTest().then('));
async function run(failAt, {external=false,screenshotFails=false,closed=false,expectedVersion}={}) {
 const calls=[]; const logs=[];
 const page={on(){},isClosed:()=>closed,goto:async()=>{throw Error('navigation sentinel')},screenshot:async()=>{calls.push('screenshot');if(screenshotFails)throw Error('screenshot sentinel')}};
 const browser={version:()=> '155.test',on(){},newPage:async()=>{if(failAt==='page')throw Error('page sentinel');return page},close:async()=>{calls.push('close')}};
 const scope={
  process:{env:{VITYO_CI_CHROME_VERSION:expectedVersion},version:'node-test',platform:'test',arch:'test'}, DEFAULT_URL:'http://127.0.0.1/editor',SCREENSHOT_PATH:'synthetic.png',
  chromium:{launch:async()=>{if(failAt==='launch')throw Error('launch sentinel');return browser}},
  resolveChromePath:async()=>{if(failAt==='resolve')throw Error('resolve sentinel');return 'synthetic'},
  ensureServer:async()=>({started:!external,child:{}}),stopServer:async()=>{calls.push('stop')},
  ensureArtifactDir:async()=>{},settle:async(p)=>{try{await p}catch{}},log:m=>logs.push(m)
 };
 vm.runInNewContext(source+'\nglobalThis.execute=runSelfTest;', scope);
 let error;try{await scope.execute()}catch(e){error=e}
 return {error,calls,logs};
}
test('launch failure preserves cause and stops owned server without nonexistent browser', async()=>{const r=await run('launch');assert.match(r.error.message,/step launch-browser failed/);assert.match(r.error.message,/launch sentinel/);assert.deepEqual(r.calls,['stop']);assert.match(r.error.message,/screenshot unavailable/)});
test('newPage failure closes browser and stops owned server',async()=>{const r=await run('page');assert.match(r.error.message,/step create-page failed/);assert.match(r.error.message,/page sentinel/);assert.deepEqual(r.calls,['close','stop'])});
test('borrowed server is not stopped',async()=>{const r=await run('page',{external:true});assert.deepEqual(r.calls,['close'])});
test('missing browser does not start or clean unrelated resources',async()=>{const r=await run('resolve');assert.match(r.error.message,/step resolve-browser failed/);assert.deepEqual(r.calls,[])});
test('failed screenshot cannot replace original navigation failure',async()=>{const r=await run('navigation',{screenshotFails:true});assert.match(r.error.message,/navigation sentinel/);assert.doesNotMatch(r.error.message,/screenshot sentinel/);assert.deepEqual(r.calls,['screenshot','close','stop'])});
test('closed page skips screenshot',async()=>{const r=await run('navigation',{closed:true});assert.match(r.error.message,/navigation sentinel/);assert.deepEqual(r.calls,['close','stop'])});
test('successful screenshot is reported accurately',async()=>{const r=await run('navigation');assert.match(r.error.message,/failure screenshot: synthetic.png/);assert.deepEqual(r.calls,['screenshot','close','stop'])});

test('CI browser drift fails before page creation and cleans up', async()=>{const r=await run('page',{expectedVersion:'147.test'});assert.match(r.error.message,/step verify-browser-version failed/);assert.match(r.error.message,/expected CI browser 147.test, got 155.test/);assert.deepEqual(r.calls,['close','stop'])});
test('matching CI browser proceeds to page creation', async()=>{const r=await run('page',{expectedVersion:'155.test'});assert.match(r.error.message,/step create-page failed/);assert.deepEqual(r.calls,['close','stop'])});
