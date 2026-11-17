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
      entrega: { nome: 'Entrega feita por nós', curto: `Entrega própria (${e.prazo_entrega})`, prazo: `${e.prazo_entrega} após o término da produção`, final: 'Entregue', prontoMsg: `Seu pedido está pronto! Agora é só aguardar a entrega: ${e.prazo_entrega}.`, fimMsg: 'Pedido entregue. Obrigado pela confiança!' },
      correios: { nome: 'Correios', curto: `Correios (postagem em ${e.prazo_correios})`, prazo: `postagem em ${e.prazo_correios} após o término da produção. O prazo de chegada é dos Correios: você recebe o código de rastreio.`, final: 'Postado', prontoMsg: `Seu pedido está pronto! A postagem nos Correios acontece em ${e.prazo_correios}.`, fimMsg: 'Pedido postado nos Correios. Acompanhe pelo código de rastreio que enviamos.' },
      retirada: { nome: 'Retirada no local', curto: 'Retirada no local', prazo: 'avisamos aqui quando estiver pronto para retirar.', final: 'Retirado', prontoMsg: 'Seu pedido está pronto para retirada!', fimMsg: 'Pedido retirado. Obrigado pela confiança!' }
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
  function aplicarCor(cor) {
    const raiz = document.documentElement.style;
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
    const meta = document.querySelector('meta[name="theme-color"]');
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

  window.CT = {
    configurado: Boolean(URL_BASE && CHAVE), URL_BASE, pedir, entrar, sair, guardarSessao, garantirToken,
    get sessao() { return sessao; }, ErroServidor, nf, moeda, data, duracao, prazoTexto, quando, diaHora, relativo,
    ETAPAS, NOME_ETAPA, ENVIO, envios, nomeEtapa, linkWhats, celular, formatarFone, el, aplicarCor, logoEstudio, iconeAba, COR_PADRAO
  };
})();
