const C='sogei-gestion-v18';
const LOCAL=['./','index.html','assets.js','manifest.json','manifest-demo.json','supabase.js','icon-192.png','icon-512.png'];
self.addEventListener('install',e=>e.waitUntil(caches.open(C).then(c=>c.addAll(LOCAL)).then(()=>self.skipWaiting())));
self.addEventListener('activate',e=>e.waitUntil(caches.keys().then(k=>Promise.all(k.filter(x=>x.startsWith('sogei-gestion')&&x!==C).map(x=>caches.delete(x)))).then(()=>self.clients.claim())));
self.addEventListener('fetch',e=>{
  if(e.request.method!=='GET')return;
  const u=new URL(e.request.url);
  if(u.origin===location.origin){
    // Réseau d'abord (mises à jour immédiates), cache si hors connexion
    e.respondWith(fetch(e.request,{cache:'no-store'}).then(res=>{const cp=res.clone();caches.open(C).then(c=>c.put(e.request,cp));return res})
      .catch(()=>caches.match(e.request,{ignoreSearch:true}).then(r=>r||caches.match('index.html'))));
    return;
  }
  e.respondWith(caches.match(e.request).then(r=>r||fetch(e.request).then(res=>{const cp=res.clone();caches.open(C).then(c=>c.put(e.request,cp));return res}).catch(()=>new Response('',{status:504}))));
});
