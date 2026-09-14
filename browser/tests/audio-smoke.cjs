// Real MediaRecorder and UI; synthetic microphone and mocked cloud/backend HTTP.
const { chromium } = require(process.env.PLAYWRIGHT_MODULE || 'playwright');
const http = require('node:http');
const fs = require('node:fs');
const path = require('node:path');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../public');
const output = process.env.AUDIO_SMOKE_OUTPUT_DIR || require('node:os').tmpdir();
const server = http.createServer((req, res) => {
  const name = req.url === '/practice' ? 'index.html' : req.url.replace('/practice-assets/', '');
  const file = path.join(root, name);
  if (!file.startsWith(root + '/') || !fs.existsSync(file)) { res.writeHead(404); return res.end(); }
  res.setHeader('Content-Type', name.endsWith('.mjs') ? 'text/javascript' : name.endsWith('.css') ? 'text/css' : 'text/html');
  res.end(fs.readFileSync(file));
});
(async () => {
 await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
 const browser = await chromium.launch({headless:true, ...(process.env.BROWSER_EXECUTABLE ? {executablePath:process.env.BROWSER_EXECUTABLE} : {})});
 try {
  const page = await browser.newPage();
  page.setDefaultTimeout(8000);
  const errors = [], uploads = [];
  let manifest, audioSaved = false, audioAttempts = 0, evaluations = 0;
  page.on('pageerror', error => errors.push(error.message));
  await page.addInitScript(() => {
   navigator.mediaDevices.getUserMedia = async () => {
    const context = new AudioContext();
    await context.resume();
    const oscillator = context.createOscillator();
    const destination = context.createMediaStreamDestination();
    oscillator.connect(destination); oscillator.start();
    window.testAudioContext = context;
    return destination.stream;
   };
   window.RTCPeerConnection = class {
    addTrack() {}
    createDataChannel() {
     const dc = this.dc = { readyState:'connecting', close() { this.readyState='closed'; },
      send(raw) {
       const msg = JSON.parse(raw);
       const emit = event => setTimeout(() => this.onmessage({data:JSON.stringify(event)}), 0);
       if (msg.type === 'session.update') emit({type:'session.updated',session:msg.session});
       if (msg.type === 'input_audio_buffer.clear') emit({type:'input_audio_buffer.cleared'});
       if (msg.type === 'input_audio_buffer.commit') {
        emit({type:'input_audio_buffer.committed',item_id:'learner1'});
        emit({type:'conversation.item.input_audio_transcription.completed',item_id:'learner1',transcript:'I enjoy discussing my work with you.'});
       }
      }
     }; return dc;
    }
    async createOffer() {return {type:'offer',sdp:'v=0\r\n'};}
    async setLocalDescription() {}
    async setRemoteDescription() {setTimeout(() => {this.dc.readyState='open';this.dc.onopen();},0);}
    close() {}
   };
  });
  await page.route('https://voice.example/**', route => route.fulfill({status:200,body:'v=0\r\n',headers:{'Access-Control-Allow-Origin':'*','Access-Control-Allow-Headers':'authorization,content-type'}}));
  await page.route('**/sessions**', async route => {
   const req = route.request(), url = new URL(req.url());
   let body = {};
   if (url.pathname === '/sessions') body = {session:{id:'test-session'},realtime:{webrtc_url:'https://voice.example/openai/v1/realtime/calls',client_credential:{value:'test-token',expires_at:new Date(Date.now()+60000).toISOString()}}};
   else if (url.pathname.endsWith('/audio')) {
    uploads.push({bytes:req.postDataBuffer(),type:req.headers()['content-type']});
    audioAttempts++;
    if (audioAttempts < 3) return route.fulfill({status:503,body:'{}'});
    audioSaved=true;
   } else if (url.pathname.endsWith('/upload-manifest')) {
    manifest=JSON.parse(req.postData()); body={ready_for_evaluation:audioSaved};
   } else if (url.pathname.endsWith('/evaluation')) { evaluations++; body={status:'completed',result:{summary:'Practice feedback',grammar:{score:4,feedback:'Grammar feedback'},vocabulary:{score:4,feedback:'Vocabulary feedback'},coherence:{score:4,feedback:'Coherence feedback'},strengths:['Clear'],next_steps:['Practice'],corrections:[]},speech_assessments:[{turn_id:manifest.audio_turn_ids[0],status:'assessed',segments:[{offset_ms:0,duration_ms:3000,text:'Recorded speech',accuracy_score:85,fluency_score:79,prosody_score:null,words:[]}]}],not_assessed:[]}; }
   await route.fulfill({status:200,contentType:'application/json',body:JSON.stringify(body)});
  });
  await page.goto(`http://127.0.0.1:${server.address().port}/practice`);
  await page.click('#start');
  await page.waitForFunction(() => !document.querySelector('#speak').disabled).catch(async error => {console.log(await page.locator('body').innerText());throw error;});
  await page.click('#speak');
  await page.waitForFunction(() => document.querySelector('#speak').textContent === 'Finish turn');
  await page.waitForTimeout(3200);
  await page.getByRole('button', {name:'End conversation',exact:true}).click();
  await page.waitForFunction(() => document.querySelector('#feedback').textContent.includes('Practice feedback'));
  const feedbackText = await page.locator('#feedback').innerText();
  assert.match(feedbackText,/Overall feedback/);
  assert.match(feedbackText,/Top priorities/);
  assert.equal(feedbackText.includes('Pronunciation and spoken fluency'), false);
  assert.equal((await page.locator('#feedback').innerText()).includes('seconds:'), false);
  assert.equal(await page.locator('#retry').count(), 0);
  assert.equal(await page.isHidden('#save-note'), true);
  assert.equal(await page.isDisabled('#evaluate'), false);
  assert.deepEqual(manifest.audio_turn_ids, manifest.transcript_turn_ids);
  assert.equal(manifest.audio_turn_ids.length,1);
  assert.ok(uploads[0].bytes.length > 1000);
  assert.ok(uploads.every(upload => upload.bytes.equals(uploads[0].bytes)));
  assert.match(uploads[0].type,/^audio\//);
  fs.writeFileSync(path.join(output, 'spoken-browser-recording.webm'),uploads[0].bytes);
  assert.equal(evaluations,1);
  assert.deepEqual(errors,[]);
  await page.screenshot({path:path.join(output, 'spoken-browser-audio-smoke.png'),fullPage:true});
  console.log(JSON.stringify({status:'passed',audioBytes:uploads[0].bytes.length,mime:uploads[0].type,identicalUploadAttempts:uploads.length,turnIds:manifest.audio_turn_ids,pageErrors:errors}));
 } finally {await browser.close();server.close();}
})().catch(error => {console.error(error);server.close();process.exitCode=1;});
