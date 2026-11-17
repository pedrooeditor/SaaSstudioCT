/* Tela que o cliente vê. Usada na página do pedido (404.html) e na demonstração da página inicial.
   CT.telaPedido(alvo, pedido, { agora, demo, semTopo }) desenha tudo dentro de "alvo". */
(() => {
  'use strict';
  const { el, nf } = CT;

  // Na demonstração, os botões não abrem o WhatsApp de ninguém.
  function botao(o, classe, texto, href) {
    return o.demo ? el('span', { class: classe, role: 'button', 'aria-disabled': 'true', text: texto })
      : el('a', { class: classe, href, target: '_blank', rel: 'noopener noreferrer', text: texto });
  }

  function caixaPix(pg, o) {
    if (!pg.pixChave) return el('p', { class: 'aviso-pg', text: 'Combine o pagamento com a gente pelo WhatsApp.' });
    const copiar = el('button', { class: 'btn btn-verde', type: 'button', text: 'Copiar chave Pix' });
    copiar.addEventListener('click', async () => {
      let ok = true;
      if (!o.demo) {
        try { await navigator.clipboard.writeText(pg.pixChave); }
        catch (_) {
          // Sem permissão para copiar: seleciona a chave para a pessoa copiar na mão.
          ok = false;
          const sel = getSelection(), faixa = document.createRange();
          faixa.selectNodeContents(copiar.parentNode.querySelector('code')); sel.removeAllRanges(); sel.addRange(faixa);
        }
      }
      copiar.textContent = ok ? 'Chave copiada ✓' : 'Chave selecionada: copie';
      setTimeout(() => { copiar.textContent = 'Copiar chave Pix'; }, 2600);
    });
    return el('div', { class: 'pix' },
      el('small', { text: 'Chave Pix' }), el('code', { text: pg.pixChave }),
      pg.pixNome ? el('span', { class: 'favorecido', text: `Favorecido: ${pg.pixNome}` }) : null, copiar);
  }

  const linha = (rotulo, valor, classe) => el('li', { class: classe || '' }, el('span', { text: rotulo }), el('b', { text: valor }));

  // O que mostrar de pagamento em cada momento do pedido.
  function cartaoPagamento(p, etapa, envio, o) {
    const pg = CT.pagamento(p.pagamento);
    if (!pg || etapa === 'cancelado') return null;
    const R = CT.dinheiro;
    const comprovante = (oQue) => p.whatsapp || o.demo
      ? botao(o, 'btn', 'Enviar comprovante pelo WhatsApp', CT.linkWhats(p.whatsapp, `Oi! Segue o comprovante do ${oQue} do pedido nº ${p.numero} (${p.titulo}).`)) : null;
    const contas = [linha('Valor do pedido', R(pg.valor)), pg.frete > 0 ? linha('Frete', R(pg.frete)) : null];

    if (pg.quitado) {
      return el('section', { class: 'cartao bloco' }, el('h2', { text: 'Pagamento' }),
        el('div', { class: 'quitado' }, el('i', { text: '✓' }), `Pagamento confirmado · ${R(pg.geral)}`));
    }
    // Pronto: falta pagar para liberar a entrega, a postagem ou a retirada.
    if (etapa === 'pronto') {
      return el('section', { class: 'cartao bloco pagar' }, el('h2', { text: 'Aguardando pagamento' }),
        el('div', { class: 'valor-grande', text: R(pg.aReceber) }),
        el('p', { class: 'valor-sub', text: `Pague para liberarmos ${envio.liberar} do seu pedido.` }),
        el('ul', { class: 'conta' }, contas,
          pg.sinalPago ? linha(`Sinal de ${nf.format(pg.pct)}% (já pago)`, '− ' + R(pg.sinal), 'pago') : null,
          linha('Total a pagar', R(pg.aReceber), 'total')),
        caixaPix(pg, o),
        el('p', { class: 'aviso-pg', text: `Depois de pagar, envie o comprovante. O pedido é liberado assim que o pagamento for confirmado.` }),
        comprovante('pagamento'));
    }
    if (etapa === 'entregue') return null;
    // Antes de começar: o sinal.
    if (pg.temSinal && !pg.sinalPago) {
      return el('section', { class: 'cartao bloco pagar' }, el('h2', { text: 'Sinal para iniciar a produção' }),
        el('div', { class: 'valor-grande', text: R(pg.sinal) }),
        el('p', { class: 'valor-sub', text: `${nf.format(pg.pct)}% do valor do pedido. A produção começa assim que o sinal for confirmado.` }),
        el('ul', { class: 'conta' }, contas,
          linha(`Sinal de ${nf.format(pg.pct)}% (agora)`, R(pg.sinal)),
          linha('Restante, quando ficar pronto', R(pg.depoisDoSinal), 'total')),
        caixaPix(pg, o), comprovante('sinal'));
    }
    // Em produção: só o resumo do que será pago quando ficar pronto.
    return el('section', { class: 'cartao bloco' }, el('h2', { text: 'Pagamento' }),
      el('ul', { class: 'conta', style: 'margin-top:0' }, contas,
        pg.sinalPago ? linha(`Sinal de ${nf.format(pg.pct)}%`, '✓ pago · ' + R(pg.sinal), 'pago') : null,
        linha('A pagar quando ficar pronto', R(pg.aReceber), 'total')));
  }

  function telaPedido(alvo, p, o = {}) {
    const estudio = p.estudio || { nome: '' };
    const agora = o.agora || Date.now();
    const tipos = CT.envios(estudio), envio = tipos[p.envio] || tipos.entrega;
    const etapa = ['pausado', 'acabamento'].includes(p.etapa) ? 'producao' : p.etapa;
    const pronto = etapa === 'pronto' || etapa === 'entregue';
    const pct = pronto ? 100 : Math.floor(p.feitos / p.quantidade * 100);
    const faltam = p.quantidade - p.feitos;
    const pg = CT.pagamento(p.pagamento);
    const esperaSinal = Boolean(pg && pg.temSinal && !pg.sinalPago && !pg.quitado && etapa === 'fila');
    const devePagar = Boolean(pg && !pg.quitado && etapa === 'pronto');

    const topo = o.semTopo ? null : el('header', { class: 'topo' },
      estudio.nome ? CT.logoEstudio(estudio, 104) : null,
      estudio.nome && !/^assets\//.test(estudio.logo || '') ? el('strong', { text: estudio.nome }) : null,
      el('small', { text: 'Acompanhamento do pedido' }));

    // Impressora: a peça cresce da porcentagem que estava na tela até a nova.
    const de = alvo._pctNaTela == null ? 0 : alvo._pctNaTela;
    alvo._pctNaTela = pct;
    const estadoImp = etapa === 'cancelado' ? 'parado' : pronto ? 'pronto' : etapa === 'producao' ? 'imprimindo' : 'fila';
    const rotuloPct = pronto ? 'concluído' : etapa === 'fila' ? 'na fila' : etapa === 'cancelado' ? 'cancelado' : 'produzido';

    // Etapas: Na fila → Em produção → Pronto → Entregue/Postado/Retirado
    const iAtual = CT.ETAPAS.indexOf(etapa);
    const etapas = el('ol', { class: 'etapas', 'aria-label': 'Etapas do pedido' },
      CT.ETAPAS.map((e, i) => {
        const feita = i < iAtual || (i === iAtual && pronto);
        return el('li', { class: feita ? 'feita' : i === iAtual ? 'atual' : '', 'aria-current': i === iAtual ? 'step' : null },
          el('span', { class: 'bola', text: feita ? '✓' : '' }), CT.nomeEtapa(e, p.envio));
      }));

    let faixa = null;
    if (etapa === 'cancelado') faixa = el('div', { class: 'faixa perigo', text: 'Este pedido foi cancelado. Fale com a gente se tiver dúvidas.' });
    else if (etapa === 'pronto') faixa = el('div', { class: 'faixa feito' }, el('i', { class: 'visto', text: '✓' }),
      el('div', {}, el('b', { text: envio.prontoTitulo }), el('span', { text: devePagar ? `Falta só o pagamento para liberarmos ${envio.liberar}.` : envio.prontoSub })));
    else if (etapa === 'entregue') faixa = el('div', { class: 'faixa feito' }, el('i', { class: 'visto', text: '✓' }), el('div', {}, el('b', { text: envio.fimMsg })));

    // Produção e envio
    let producao = null;
    if (!pronto && etapa !== 'cancelado') {
      const resta = CT.data(p.termino).getTime() - agora, atraso = resta < 0;
      producao = el('section', { class: 'cartao bloco' },
        esperaSinal
          ? [el('h2', { text: 'Produção' }), el('div', { class: 'contagem', text: 'A produção começa assim que o sinal for confirmado.' })]
          : [el('h2', { text: 'Término previsto da produção' }),
            el('div', { class: 'data-grande', text: CT.quando(p.termino) }),
            el('div', { class: 'contagem' + (atraso ? ' atraso' : ''), text: atraso ? 'A produção está levando um pouco mais que o previsto. Já já atualizamos por aqui.' : `Faltam ${CT.duracao(resta)}` }),
            p.ritmo_horas ? el('p', { class: 'detalhe' }, 'No ritmo atual, ', el('b', { text: `${nf.format(faltam)} restante${faltam === 1 ? '' : 's'} em cerca de ${CT.duracao(Number(p.ritmo_horas) * 3600000)}` }), '.') : null],
        el('hr', { class: 'divisor' }),
        el('h2', { text: p.envio === 'retirada' ? 'Retirada' : 'Entrega' }),
        el('p', { class: 'detalhe', style: 'margin:0' }, el('b', { text: envio.nome + ': ' }), envio.prazo));
    }

    const pagamento = cartaoPagamento(p, etapa, envio, o);
    const recado = p.mensagem && p.mensagem.trim()
      ? el('section', { class: 'cartao bloco recado' }, el('h2', { text: estudio.nome ? `Recado de ${estudio.nome}` : 'Recado' }), el('p', { text: p.mensagem }))
      : null;
    const whats = p.whatsapp || o.demo
      ? botao(o, 'btn btn-cor btn-whats', 'Falar com a gente no WhatsApp', CT.linkWhats(p.whatsapp, p.numero ? `Oi, tudo bem? Meu pedido é o nº ${p.numero} (${p.titulo}).` : `Oi, tudo bem? Meu pedido é "${p.titulo}".`))
      : null;
    // O que pede ação do cliente (pagar) vem antes das etapas; o resumo do pagamento vem depois da produção.
    const pedeAcao = devePagar || (pagamento && pagamento.classList.contains('pagar'));

    alvo.classList.add('acomp');
    alvo.classList.toggle('concluido', pronto);
    alvo.replaceChildren(...[
      topo,
      el('section', { class: 'cartao' },
        el('div', { class: 'linha-tag' }, p.tipo ? el('span', { class: 'tipo', text: p.tipo }) : el('span'),
          p.numero ? el('span', { class: 'numero', text: `Pedido nº ${p.numero}` }) : null),
        el('h1', { class: 'titulo', text: p.titulo }),
        p.cliente ? el('p', { class: 'ola', text: `Olá, ${p.cliente}! Veja como está o seu pedido.` }) : null,
        el('div', { class: 'progresso' }, CT.impressora(pct, estadoImp, de),
          el('div', { class: 'lado' },
            el('div', { class: 'pct' }, el('b', { text: `${pct}%` }), el('span', { text: rotuloPct })),
            el('div', { class: 'numeros' },
              el('div', { class: 'num' }, el('span', { text: 'Prontos' }), el('b', { text: nf.format(p.feitos) })),
              el('div', { class: 'num' }, el('span', { text: 'Faltam' }), el('b', { text: nf.format(faltam) })),
              el('div', { class: 'num' }, el('span', { text: 'Total do pedido' }), el('b', { text: nf.format(p.quantidade) })))))),
      faixa,
      pedeAcao ? pagamento : null,
      etapa === 'cancelado' ? null : el('section', { class: 'cartao' }, etapas),
      producao,
      pedeAcao ? null : pagamento,
      recado, whats,
      o.demo ? null : el('p', { class: 'rodape', text: `Atualizado ${CT.relativo(p.atualizado_em, agora)} · esta página se atualiza sozinha` })
    ].filter(Boolean));
  }

  CT.telaPedido = telaPedido;
})();
