// Recebe os avisos da Cakto (pagamento aprovado, renovação, atraso, cancelamento, reembolso)
// e repassa para o banco, que libera ou corta o acesso do estúdio.
// Publicada sem exigir login (a Cakto não manda token do Supabase): a origem é conferida
// pela assinatura HMAC do cabeçalho X-Cakto-Signature ou, na falta dela, pelo campo "secret".

const URL_BASE = Deno.env.get('SUPABASE_URL') ?? '';
const CHAVE_SERVICO = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
const TOLERANCIA_SEG = 5 * 60;

let segredoCache = { valor: '', ate: 0 };

async function rpc(nome: string, corpo: unknown) {
  const r = await fetch(`${URL_BASE}/rest/v1/rpc/${nome}`, {
    method: 'POST',
    headers: { apikey: CHAVE_SERVICO, authorization: `Bearer ${CHAVE_SERVICO}`, 'content-type': 'application/json' },
    body: JSON.stringify(corpo),
  });
  const texto = await r.text();
  if (!r.ok) throw new Error(`${nome}: ${r.status} ${texto.slice(0, 200)}`);
  return texto ? JSON.parse(texto) : null;
}

async function segredo(): Promise<string> {
  if (segredoCache.ate > Date.now()) return segredoCache.valor;
  const valor = (await rpc('ct_srv_cakto_segredo', {})) ?? '';
  segredoCache = { valor, ate: Date.now() + 60_000 };
  return valor;
}

function iguais(a: string, b: string) {
  if (a.length !== b.length) return false;
  let d = 0;
  for (let i = 0; i < a.length; i++) d |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return d === 0;
}

async function hmacHex(chave: string, texto: Uint8Array) {
  const k = await crypto.subtle.importKey('raw', new TextEncoder().encode(chave), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', k, texto));
  return [...sig].map(b => b.toString(16).padStart(2, '0')).join('');
}

// Confere que veio da Cakto: prefere a assinatura do cabeçalho (prova a origem sem ler o segredo do corpo).
async function veioDaCakto(req: Request, bruto: Uint8Array, corpo: { secret?: string }, chave: string) {
  const assinatura = req.headers.get('x-cakto-signature');
  const momento = req.headers.get('x-cakto-timestamp');
  if (assinatura && momento) {
    if (!/^\d+$/.test(momento) || Math.abs(Date.now() / 1000 - Number(momento)) > TOLERANCIA_SEG) return false;
    const prefixo = new TextEncoder().encode(`${momento}.`);
    const junto = new Uint8Array(prefixo.length + bruto.length);
    junto.set(prefixo); junto.set(bruto, prefixo.length);
    const esperado = `v1=${await hmacHex(chave, junto)}`;
    // Em uma troca de versão podem vir várias assinaturas separadas por vírgula.
    return assinatura.split(',').map(x => x.trim()).some(x => iguais(x, esperado));
  }
  return typeof corpo.secret === 'string' && iguais(corpo.secret, chave);
}

const resposta = (status: number, dados: unknown) =>
  new Response(JSON.stringify(dados), { status, headers: { 'content-type': 'application/json' } });

Deno.serve(async (req) => {
  if (req.method !== 'POST') return resposta(405, { erro: 'use POST' });
  const bruto = new Uint8Array(await req.arrayBuffer());
  let corpo: { secret?: string; event?: string; data?: unknown };
  try { corpo = JSON.parse(new TextDecoder().decode(bruto)); } catch { return resposta(400, { erro: 'JSON inválido' }); }

  let chave = '';
  try { chave = await segredo(); } catch (e) { console.error(e); return resposta(503, { erro: 'banco indisponível' }); }
  if (!chave) return resposta(503, { erro: 'segredo do webhook ainda não configurado no painel' });
  if (!(await veioDaCakto(req, bruto, corpo, chave))) return resposta(401, { erro: 'origem não confirmada' });

  const evento = String(corpo.event ?? '');
  // Webhook "V2" da Cakto manda uma lista de pedidos em data; o V1 manda um objeto.
  const itens = Array.isArray(corpo.data) ? corpo.data : [corpo.data];
  const resultados = [];
  for (const dados of itens) {
    if (!dados || typeof dados !== 'object') continue;
    if (evento === 'checkout_abandonment') { resultados.push({ ignorado: true }); continue; }
    try { resultados.push(await rpc('ct_srv_cakto_receber', { p_evento: evento, p_dados: dados })); }
    catch (e) { console.error(e); return resposta(500, { erro: 'falha ao gravar' }); }
  }
  return resposta(200, { ok: true, evento, resultados });
});
