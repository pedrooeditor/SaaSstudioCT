/* Studio CT: funções comuns às duas páginas (servidor, login, datas). */
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

  const ETAPAS = [
    { id: 'fila', nome: 'Na fila' },
    { id: 'producao', nome: 'Em produção' },
    { id: 'acabamento', nome: 'Acabamento' },
    { id: 'pronto', nome: 'Pronto' },
    { id: 'entregue', nome: 'Entregue' }
  ];
  const NOME_ETAPA = { fila: 'Na fila', producao: 'Em produção', pausado: 'Pausado', acabamento: 'Acabamento e embalagem', pronto: 'Pronto para entrega', entregue: 'Entregue', cancelado: 'Cancelado' };

  // WhatsApp: números brasileiros sem o 55 ganham o código do país.
  function linkWhats(numero, texto) {
    let n = String(numero || '').replace(/\D/g, '');
    if (n.length === 10 || n.length === 11) n = '55' + n;
    return `https://wa.me/${n}?text=${encodeURIComponent(texto)}`;
  }

  // Ritmo de produção: peças prontas por hora desde o início do pedido.
  function ritmo(p, agora) {
    if (!p.feitos || p.feitos >= p.quantidade) return null;
    const horas = (agora - data(p.inicio).getTime()) / 3600000;
    if (horas < 1) return null; // pouco tempo de produção ainda: estimativa não seria confiável
    const porHora = p.feitos / horas;
    if (!(porHora > 0) || !Number.isFinite(porHora)) return null;
    return { porHora, faltamMs: (p.quantidade - p.feitos) / porHora * 3600000 };
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

  // Cor da marca vinda das configurações do estúdio.
  function aplicarCor(cor) {
    if (!/^#[0-9A-F]{6}$/i.test(cor || '')) return;
    document.documentElement.style.setProperty('--cor', cor);
  }

  window.CT = {
    configurado: Boolean(URL_BASE && CHAVE), URL_BASE, pedir, entrar, sair, guardarSessao, garantirToken,
    get sessao() { return sessao; }, ErroServidor, nf, moeda, data, duracao, prazoTexto, quando, diaHora, relativo,
    ETAPAS, NOME_ETAPA, linkWhats, ritmo, el, aplicarCor
  };
})();
