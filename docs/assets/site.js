(function(){
  var root=document.documentElement;

  /* ---- language toggle ---- */
  var bEn=document.getElementById('lang-en'), bDe=document.getElementById('lang-de');
  function setLang(l){
    root.dataset.locale=l; root.lang=l;
    bEn.setAttribute('aria-pressed', l==='en');
    bDe.setAttribute('aria-pressed', l==='de');
    try{localStorage.setItem('ku-lang',l);}catch(e){}
  }
  bEn.addEventListener('click',function(){setLang('en');});
  bDe.addEventListener('click',function(){setLang('de');});
  setLang(root.dataset.locale==='de'?'de':'en');

  /* ---- theme toggle ---- */
  document.getElementById('theme-toggle').addEventListener('click',function(){
    var cur=root.dataset.theme;
    if(cur!=='dark'&&cur!=='light'){
      cur=(window.matchMedia&&window.matchMedia('(prefers-color-scheme: dark)').matches)?'dark':'light';
    }
    var next=cur==='dark'?'light':'dark';
    root.dataset.theme=next;
    try{localStorage.setItem('ku-theme',next);}catch(e){}
  });

  /* ---- tiny yaml/bash highlighter (display only) ---- */
  document.querySelectorAll('pre[data-hl]').forEach(function(pre){
    var lang=pre.getAttribute('data-hl');
    if(lang==='none') return;
    var esc=pre.innerHTML;
    pre.innerHTML=esc.split('\n').map(function(line){
      if(lang==='bash'){
        if(/^\s*#/.test(line)) return '<span class="c">'+line+'</span>';
        return line.replace(/^(\s*)(helm|kubectl|oc|git|mkdir)(\s|$)/,'$1<span class="k">$2</span>$3');
      }
      /* yaml */
      var ci=-1;
      for(var i=0;i<line.length;i++){
        if(line[i]==='#'&&(i===0||/\s/.test(line[i-1]))){ci=i;break;}
      }
      var head=ci>-1?line.slice(0,ci):line, comment=ci>-1?line.slice(ci):'';
      /* strings first, keys second - the key span's own class="k" attribute
         must never be visible to the string regex */
      head=head.replace(/"([^"]*)"/g,'<span class="s">"$1"</span>');
      head=head.replace(/^(\s*(?:- )?)([A-Za-z0-9_.\/{}-]+)(:)(?=\s|$)/,'$1<span class="k">$2</span>$3');
      return head+(comment?'<span class="c">'+comment+'</span>':'');
    }).join('\n');
  });

  /* ---- copy buttons ---- */
  document.querySelectorAll('figure.code').forEach(function(fig){
    var cap=fig.querySelector('figcaption'), pre=fig.querySelector('pre');
    if(!cap||!pre) return;
    var btn=document.createElement('button');
    btn.className='copy'; btn.type='button';
    btn.innerHTML='<span data-lang="en">copy</span><span data-lang="de">kopieren</span>';
    btn.addEventListener('click',function(){
      var ok=function(){btn.innerHTML='<span data-lang="en">copied</span><span data-lang="de">kopiert</span>';setTimeout(function(){btn.innerHTML='<span data-lang="en">copy</span><span data-lang="de">kopieren</span>';},1400);};
      if(navigator.clipboard&&navigator.clipboard.writeText){navigator.clipboard.writeText(pre.textContent).then(ok,function(){});}
    });
    cap.appendChild(btn);
  });

  /* ---- active TOC link ---- */
  var links=[].slice.call(document.querySelectorAll('.toc a'));
  var secs=links.map(function(a){return document.querySelector(a.getAttribute('href'));}).filter(Boolean);
  if('IntersectionObserver' in window){
    var active=null;
    var io=new IntersectionObserver(function(entries){
      entries.forEach(function(en){
        if(en.isIntersecting){
          links.forEach(function(a){a.classList.toggle('active',a.getAttribute('href')==='#'+en.target.id);});
        }
      });
    },{rootMargin:'-20% 0px -70% 0px'});
    secs.forEach(function(s){io.observe(s);});
  }
})();
