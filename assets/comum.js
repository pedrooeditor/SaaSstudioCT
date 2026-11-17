/* Acompanhamento de pedidos: funções comuns às duas páginas (servidor, login, datas). */
(() => {
  'use strict';
  const CFG = window.STUDIOCT_CONFIG || {};
  const URL_BASE = String(CFG.supabaseUrl || '').replace(/\/+$/, '');
  const CHAVE = String(CFG.supabaseKey || '');
  const SESSAO_KEY = 'studioct.sessao.v1';

  class ErroServidor extends Error {}

  const ls = {
    get(k) { try { return JSON.parse(localStorage.getItem(k) || 'null'); } catch (_) { return null; } },
    set(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (_) {} },
    del(k) { try { localStorage.removeItem(k); } catch (_) {} }
  };

  let sessao = ls.get(SESSAO_KEY);

  async function pedir(caminho, { metodo = 'GET', corpo, cabecalhos = {}, comLogin = false } = {}) {
    if (comLogin) await garantirToken();
    let res;
    try {
      res = await fetch(URL_BASE + caminho, {
        method: metodo,
        headers: Object.assign({ apikey: CHAVE, 'content-type': 'application/json' },
          comLogin && sessao ? { authorization: 'Bearer ' + sessao.access_token } : {}, cabecalhos),
        body: corpo === undefined ? undefined : JSON.stringify(corpo)
      });
    } catch (_) {
      throw Object.assign(new ErroServidor(navigator.onLine === false ? 'Sem internet.' : 'Não consegui falar com o servidor.'), { status: 0 });
    }
    const txt = await res.text();
    let dados = null;
    try { dados = txt ? JSON.parse(txt) : null; } catch (_) { dados = txt; }
    if (res.ok) return dados;
    const msg = (dados && (dados.msg || dados.message || dados.error_description || dados.error)) || 'Erro do servidor.';
    throw Object.assign(new ErroServidor(String(msg)), { status: res.status, dados });
  }

  function guardarSessao(d) {
    if (!d || !d.access_token) throw new ErroServidor('Resposta de login inválida.');
    sessao = {
      access_token: d.access_token,
      refresh_token: d.refresh_token,
      expires_at: d.expires_at || Math.floor(Date.now() / 1000) + (d.expires_in || 3600),
      email: (d.user && d.user.email) || (sessao && sessao.email) || ''
    };
    ls.set(SESSAO_KEY, sessao);
  }

  async function garantirToken() {
    if (!sessao) throw Object.assign(new ErroServidor('Entre de novo.'), { status: 401 });
    if (sessao.expires_at - 60 > Date.now() / 1000) return;
    try {
      guardarSessao(await pedir('/auth/v1/token?grant_type=refresh_token', { metodo: 'POST', corpo: { refresh_token: sessao.refresh_token } }));
    } catch (e) {
      if (e.status >= 400 && e.status < 500) { sessao = null; ls.del(SESSAO_KEY); }
      throw e;
    }
  }

  async function entrar(email, senha) {
    guardarSessao(await pedir('/auth/v1/token?grant_type=password', { metodo: 'POST', corpo: { email, password: senha } }));
    sessao.email = email; ls.set(SESSAO_KEY, sessao);
  }
  async function sair() {
    try { if (sessao) await fetch(URL_BASE + '/auth/v1/logout', { method: 'POST', headers: { apikey: CHAVE, authorization: 'Bearer ' + sessao.access_token } }); } catch (_) {}
    sessao = null; ls.del(SESSAO_KEY);
  }

  // ---------- Datas e números em português ----------
  const nf = new Intl.NumberFormat('pt-BR');
  const moeda = new Intl.NumberFormat('pt-BR', { style: 'currency', currency: 'BRL' });
  // O Safari antigo não entende frações de segundo com mais de 3 casas.
  const data = v => v instanceof Date ? v : new Date(String(v).replace(/(\.\d{3})\d+/, '$1'));
  function duracao(ms) {
    const neg = ms < 0; ms = Math.abs(ms);
    const min = Math.round(ms / 60000), h = Math.floor(min / 60), d = Math.floor(h / 24);
    let t;
    if (d >= 1) { const hr = h % 24; t = `${d} dia${d > 1 ? 's' : ''}` + (hr && d < 7 ? ` e ${hr} h` : ''); }
    else if (h >= 1) { const m = min % 60; t = `${h} h` + (m && h < 6 ? ` e ${m} min` : ''); }
    else t = `${Math.max(1, min)} min`;
    return neg ? '-' + t : t;
  }
  function prazoTexto(horas) {
    const h = Number(horas);
    if (h % 24 === 0) { const d = h / 24; return `${nf.format(d)} dia${d === 1 ? '' : 's'}`; }
    if (h > 48) return `${nf.format(Math.round(h / 24 * 10) / 10)} dias`;
    return `${nf.format(h)} hora${h === 1 ? '' : 's'}`;
  }
  const quando = v => data(v).toLocaleString('pt-BR', { weekday: 'short', day: '2-digit', month: 'short', hour: '2-digit', minute: '2-digit' }).replace(/\./g, '');
  const diaHora = v => data(v).toLocaleString('pt-BR', { day: '2-digit', month: '2-digit', hour: '2-digit', minute: '2-digit' });
  function relativo(v, agora = Date.now()) {
    const s = Math.round((agora - data(v).getTime()) / 1000);
    if (s < 60) return 'agora mesmo';
    if (s < 3600) return `há ${Math.round(s / 60)} min`;
    if (s < 86400) return `há ${Math.round(s / 3600)} h`;
    const d = Math.round(s / 86400);
    return d === 1 ? 'ontem' : `há ${d} dias`;
  }

  const ETAPAS = ['fila', 'producao', 'pronto', 'entregue'];
  const NOME_ETAPA = { fila: 'Na fila', producao: 'Em produção', pronto: 'Pronto', entregue: 'Entregue', cancelado: 'Cancelado', pausado: 'Em produção', acabamento: 'Em produção' };
  // Tipos de envio e o que o cliente vê em cada um. Os prazos vêm das configurações de cada estúdio.
  const PRAZOS_PADRAO = { prazo_entrega: 'de 2 a 5 dias corridos', prazo_correios: '2 a 3 dias úteis' };
  function envios(estudio) {
    const e = Object.assign({}, PRAZOS_PADRAO, estudio || {});
    return {
      entrega: { nome: 'Entrega feita por nós', curto: `Entrega própria (${e.prazo_entrega})`, prazo: `${e.prazo_entrega} após o término da produção`, final: 'Entregue', liberar: 'a entrega', prontoTitulo: 'Seu pedido está pronto!', prontoSub: `Agora é só aguardar a entrega: ${e.prazo_entrega}.`, prontoMsg: `Seu pedido está pronto! Agora é só aguardar a entrega: ${e.prazo_entrega}.`, fimMsg: 'Pedido entregue. Obrigado pela confiança!' },
      correios: { nome: 'Correios', curto: `Correios (postagem em ${e.prazo_correios})`, prazo: `postagem em ${e.prazo_correios} após o término da produção. O prazo de chegada é dos Correios: você recebe o código de rastreio.`, final: 'Postado', liberar: 'a postagem nos Correios', prontoTitulo: 'Seu pedido está pronto!', prontoSub: `A postagem nos Correios acontece em ${e.prazo_correios}.`, prontoMsg: `Seu pedido está pronto! A postagem nos Correios acontece em ${e.prazo_correios}.`, fimMsg: 'Pedido postado nos Correios. Acompanhe pelo código de rastreio que enviamos.' },
      retirada: { nome: 'Retirada no local', curto: 'Retirada no local', prazo: 'avisamos aqui quando estiver pronto para retirar.', final: 'Retirado', liberar: 'a retirada', prontoTitulo: 'Seu pedido está pronto para retirada!', prontoSub: 'Já pode vir buscar.', prontoMsg: 'Seu pedido está pronto para retirada!', fimMsg: 'Pedido retirado. Obrigado pela confiança!' }
    };
  }
  const ENVIO = envios();
  const nomeEtapa = (etapa, envio) => etapa === 'entregue' ? (ENVIO[envio] || ENVIO.entrega).final : etapa === 'pronto' && envio === 'retirada' ? 'Pronto para retirada' : NOME_ETAPA[etapa] || etapa;

  // Telefone brasileiro só com DDD + número: tira zeros à esquerda e o 55, e acrescenta o 9
  // que falta em celular digitado no formato antigo (10 dígitos começando em 6 a 9).
  function celular(v) {
    let n = String(v || '').replace(/\D/g, '').replace(/^0+/, '');
    if ((n.length === 12 || n.length === 13) && n.startsWith('55')) n = n.slice(2);
    if (n.length === 10 && /[6-9]/.test(n[2])) n = n.slice(0, 2) + '9' + n.slice(2);
    return n;
  }
  function formatarFone(v) {
    const n = celular(v);
    if (n.length === 11) return `(${n.slice(0, 2)}) ${n.slice(2, 7)}-${n.slice(7)}`;
    if (n.length === 10) return `(${n.slice(0, 2)}) ${n.slice(2, 6)}-${n.slice(6)}`;
    return n;
  }
  // WhatsApp: números brasileiros ganham o código do país. Sem número, o WhatsApp deixa escolher o contato.
  function linkWhats(numero, texto) {
    let n = celular(numero);
    if (n.length === 10 || n.length === 11) n = '55' + n;
    return `https://wa.me/${n}?text=${encodeURIComponent(texto)}`;
  }

  const el = (tag, props = {}, ...filhos) => {
    const n = document.createElement(tag);
    for (const [k, v] of Object.entries(props)) {
      if (v == null || v === false) continue;
      if (k === 'class') n.className = v;
      else if (k === 'text') n.textContent = v;
      else if (k.startsWith('on')) n.addEventListener(k.slice(2), v);
      else n.setAttribute(k, v === true ? '' : v);
    }
    const add = c => { if (Array.isArray(c)) c.forEach(add); else if (c != null && c !== false) n.append(c); };
    filhos.forEach(add);
    return n;
  };

  // Cor da marca de cada estúdio. O dourado padrão usa a paleta original; outras cores geram uma paleta parecida.
  const COR_PADRAO = '#B8862B';
  const hexRgb = h => [1, 3, 5].map(i => parseInt(h.slice(i, i + 2), 16));
  const rgbHex = c => '#' + c.map(v => Math.round(Math.max(0, Math.min(255, v))).toString(16).padStart(2, '0')).join('').toUpperCase();
  const misturar = (a, b, t) => rgbHex(hexRgb(a).map((v, i) => v + (hexRgb(b)[i] - v) * t));
  const luz = h => { const [r, g, b] = hexRgb(h).map(v => { v /= 255; return v <= .03928 ? v / 12.92 : ((v + .055) / 1.055) ** 2.4; }); return .2126 * r + .7152 * g + .0722 * b; };
  function aplicarCor(cor, alvo) {
    const pagina = !alvo;
    const raiz = (alvo || document.documentElement).style;
    const props = ['--cor', '--ouro', '--ouro-claro', '--fundo', '--cartao', '--linha', '--trilho', '--rodape-dlg', '--texto-btn', '--borda-btn'];
    props.forEach(p => raiz.removeProperty(p));
    if (!/^#[0-9A-F]{6}$/i.test(cor || '') || cor.toUpperCase() === COR_PADRAO) return;
    cor = cor.toUpperCase();
    const escura = misturar(cor, '#000000', .18);
    const media = misturar(cor, '#FFFFFF', .22);
    raiz.setProperty('--cor', luz(cor) > .45 ? escura : cor);
    raiz.setProperty('--ouro', media);
    raiz.setProperty('--ouro-claro', misturar(cor, '#FFFFFF', .55));
    raiz.setProperty('--fundo', misturar(cor, '#FFFFFF', .9));
    raiz.setProperty('--cartao', misturar(cor, '#FFFFFF', .975));
    raiz.setProperty('--linha', misturar(cor, '#FFFFFF', .78));
    raiz.setProperty('--trilho', misturar(cor, '#FFFFFF', .82));
    raiz.setProperty('--rodape-dlg', misturar(cor, '#FFFFFF', .94));
    raiz.setProperty('--borda-btn', escura);
    raiz.setProperty('--texto-btn', luz(media) > .35 ? '#1F1A17' : '#FFFFFF');
    const meta = pagina && document.querySelector('meta[name="theme-color"]');
    if (meta) meta.setAttribute('content', misturar(cor, '#FFFFFF', .9));
  }
  // Logo do estúdio (ou a inicial do nome, quando não tem logo).
  // Logos que são arquivos do site: a proporção já conhecida reserva o espaço antes de a imagem chegar.
  const PROPORCAO_LOGO = { 'assets/logo.webp': '357 / 420' };
  function logoEstudio(estudio, tamanho, classe) {
    const e = estudio || {};
    const prop = PROPORCAO_LOGO[e.logo];
    if (e.logo) return el('img', { class: classe || '', src: e.logo, alt: e.nome || '', decoding: 'async',
      style: `width:${tamanho}px;height:auto;max-height:${Math.round(tamanho * 1.25)}px;object-fit:contain` + (prop ? `;aspect-ratio:${prop}` : '') });
    const inicial = String(e.nome || '?').trim().charAt(0).toUpperCase() || '?';
    return el('span', { class: 'inicial ' + (classe || ''), 'aria-hidden': 'true', style: `width:${tamanho}px;height:${tamanho}px;font-size:${Math.round(tamanho * .45)}px`, text: inicial });
  }
  function iconeAba(estudio) {
    if (!estudio || !estudio.logo) return;
    document.querySelectorAll('link[rel="icon"]').forEach(l => { l.href = estudio.logo; l.removeAttribute('type'); });
  }

  // ---------- Pagamento: contas a partir do que está no pedido ----------
  // O sinal é uma parte do valor do pedido (sem o frete). O restante, mais o frete, é pago quando fica pronto.
  function pagamento(pg) {
    if (!pg || pg.valor == null) return null;
    const valor = Number(pg.valor) || 0, frete = Number(pg.frete) || 0, pct = Number(pg.sinal_pct) || 0;
    const sinal = Math.round(valor * pct) / 100;
    const sinalPago = Boolean(pg.sinal_pago) && sinal > 0;
    const geral = Math.round((valor + frete) * 100) / 100;
    return {
      valor, frete, geral, pct, sinal, temSinal: sinal > 0, sinalPago, quitado: Boolean(pg.quitado),
      aReceber: Math.round((geral - (sinalPago ? sinal : 0)) * 100) / 100,   // o que falta quando o pedido fica pronto
      depoisDoSinal: Math.round((geral - sinal) * 100) / 100,                 // restante previsto, com o sinal em dia
      pixChave: pg.pix_chave || '', pixNome: pg.pix_nome || ''
    };
  }
  const dinheiro = v => moeda.format(Number(v) || 0);
  // Aceita "150", "150,5", "1.500,00" e "1500.00". Vazio = null; inválido = NaN.
  function lerDinheiro(txt) {
    let t = String(txt == null ? '' : txt).replace(/[R$\s]/g, '');
    if (!t) return null;
    if (/,/.test(t)) t = t.replace(/\./g, '').replace(',', '.');
    const n = Number(t);
    return Number.isFinite(n) && n >= 0 ? Math.round(n * 100) / 100 : NaN;
  }

  // ---------- Impressora 3D que mostra o andamento do pedido ----------
  // estado: 'fila' (parada), 'imprimindo' (cabeça andando), 'pronto' (peça verde, com o visto) ou 'parado'.
  // "de" é a porcentagem que estava na tela antes: a peça cresce de lá até a nova porcentagem.
  let serieImpressora = 0;
  const BASE_PECA = 158, ALTURA_PECA = 84;
  const PECA = 'M82 158C71 142 68 124 76 110C82 100 89 93 89 84C89 79 85 77 82 74L118 74C115 77 111 79 111 84C111 93 118 100 124 110C132 124 129 142 118 158Z';
  function impressora(pct, estado, de) {
    pct = Math.max(0, Math.min(100, Number(pct) || 0));
    const pronto = estado === 'pronto', andando = estado === 'imprimindo' && pct < 100;
    const id = 'imp' + (++serieImpressora);
    const cor = pronto ? ['var(--verde-claro)', 'var(--verde)', 'var(--verde-escuro)'] : ['var(--ouro-claro)', 'var(--ouro)', 'var(--cor)'];
    const svg = `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 200 196" aria-hidden="true">
      <defs>
        <linearGradient id="${id}g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" style="stop-color:${cor[0]}"/><stop offset=".55" style="stop-color:${cor[1]}"/><stop offset="1" style="stop-color:${cor[2]}"/></linearGradient>
        <clipPath id="${id}c"><rect class="imp-corte" x="56" y="${BASE_PECA}" width="88" height="0"/></clipPath>
        <pattern id="${id}l" width="6" height="3.5" patternUnits="userSpaceOnUse"><path d="M0 3.2H6" stroke="#000" stroke-opacity=".13" stroke-width=".9"/></pattern>
      </defs>
      <ellipse cx="100" cy="161" rx="34" ry="3.2" class="imp-sombra"/>
      <rect x="16" y="166" width="168" height="22" rx="9" class="imp-maquina"/>
      <rect x="40" y="158" width="120" height="8" rx="3.5" class="imp-mesa"/>
      <rect x="27" y="30" width="9" height="140" rx="3" class="imp-maquina"/>
      <rect x="164" y="30" width="9" height="140" rx="3" class="imp-maquina"/>
      <rect x="22" y="12" width="156" height="26" rx="9" class="imp-maquina"/>
      <rect x="70" y="17.5" width="60" height="15" rx="4" class="imp-tela"/>
      <text x="100" y="29" text-anchor="middle" class="imp-tela-txt">${pronto ? '100%' : estado === 'fila' && pct === 0 ? 'na fila' : Math.floor(pct) + '%'}</text>
      <circle cx="36" cy="25" r="2.6" class="imp-led"/>
      <circle cx="161" cy="177" r="3" class="imp-botao"/><rect x="28" y="175" width="26" height="4" rx="2" class="imp-botao"/>
      <path d="${PECA}" class="imp-fantasma"/>
      <g clip-path="url(#${id}c)"><path d="${PECA}" fill="url(#${id}g)"/><path d="${PECA}" fill="url(#${id}l)"/><path d="M84 152C76 138 74 124 80 112" class="imp-reflexo"/></g>
      <g class="imp-eixo" transform="translate(0 ${BASE_PECA - 20})">
        <rect x="36" y="0" width="128" height="6" rx="3" class="imp-trilho"/>
        <g class="imp-cabeca">
          <rect x="87" y="-6" width="26" height="17" rx="4.5" class="imp-carro"/>
          <rect x="91" y="-2.5" width="18" height="3" rx="1.5" class="imp-carro-luz"/>
          <path d="M94.5 11h11l-3.4 9h-4.2z" class="imp-bico"/>
          <circle cx="100" cy="20" r="2.4" class="imp-quente"/>
        </g>
      </g>
      ${pronto ? `<g class="imp-feito"><circle cx="150" cy="92" r="15" class="imp-visto-fundo"/><path d="M143 92.5l5 5 9.5-10.5" class="imp-visto"/>
        <path d="M52 86l1.8 4.4 4.4 1.8-4.4 1.8-1.8 4.4-1.8-4.4-4.4-1.8 4.4-1.8z" class="imp-estrela e1"/><path d="M146 58l1.3 3.2 3.2 1.3-3.2 1.3-1.3 3.2-1.3-3.2-3.2-1.3 3.2-1.3z" class="imp-estrela e2"/><path d="M60 122l1.1 2.7 2.7 1.1-2.7 1.1-1.1 2.7-1.1-2.7-2.7-1.1 2.7-1.1z" class="imp-estrela e3"/></g>` : ''}
    </svg>`;
    const caixa = el('div', { class: 'imp' + (andando ? ' andando' : ' parada') + (pronto ? ' pronta' : '') + (Number(de) === pct ? ' quieta' : ''), role: 'img', 'aria-label': pronto ? 'Pedido pronto' : `${Math.floor(pct)}% pronto` });
    caixa.append(document.importNode(new DOMParser().parseFromString(svg, 'image/svg+xml').documentElement, true));
    const corte = caixa.querySelector('.imp-corte'), eixo = caixa.querySelector('.imp-eixo');
    const por = v => {
      v = Math.max(0, Math.min(100, v));
      const topo = BASE_PECA - ALTURA_PECA * v / 100;
      corte.setAttribute('y', topo); corte.setAttribute('height', BASE_PECA - topo);
      // Parada (na fila ou pronta), a cabeça sobe e descansa; imprimindo, o bico encosta na última camada.
      eixo.setAttribute('transform', `translate(0 ${andando || (estado !== 'pronto' && v > 0) ? topo - 20 : 44})`);
    };
    const inicio = Math.max(0, Math.min(100, Number(de) || 0));
    const semMovimento = typeof matchMedia === 'function' && matchMedia('(prefers-reduced-motion: reduce)').matches;
    if (semMovimento || inicio === pct || typeof requestAnimationFrame !== 'function') por(pct);
    else {
      por(inicio);
      const t0 = performance.now(), dur = 500 + Math.min(900, Math.abs(pct - inicio) * 14);
      const passo = t => { const k = Math.max(0, Math.min(1, (t - t0) / dur)), e = 1 - (1 - k) ** 3; por(inicio + (pct - inicio) * e); if (k < 1) requestAnimationFrame(passo); };
      requestAnimationFrame(passo);
    }
    return caixa;
  }

  window.CT = {
    configurado: Boolean(URL_BASE && CHAVE), URL_BASE, pedir, entrar, sair, guardarSessao, garantirToken,
    get sessao() { return sessao; }, ErroServidor, nf, moeda, data, duracao, prazoTexto, quando, diaHora, relativo,
    ETAPAS, NOME_ETAPA, ENVIO, envios, nomeEtapa, linkWhats, celular, formatarFone, el, aplicarCor, logoEstudio, iconeAba, COR_PADRAO, pagamento, dinheiro, lerDinheiro, impressora
  };
})();
