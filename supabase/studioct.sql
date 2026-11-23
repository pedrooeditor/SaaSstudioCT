-- =====================================================================
-- Studio CT | Acompanhamento de pedidos
-- Rode no Supabase: SQL Editor > New query > Run. Pode rodar de novo sem perder dados.
-- Clientes NUNCA leem as tabelas direto: só pela função ct_pedido_publico(codigo),
-- que devolve apenas o pedido daquele link e só os campos que o cliente pode ver.
-- =====================================================================

create extension if not exists pgcrypto;

-- Quem administra (lança e atualiza pedidos).
create table if not exists public.ct_admins (
  email text primary key check (email = lower(email))
);
alter table public.ct_admins enable row level security;
revoke all on public.ct_admins from anon, authenticated;

create or replace function public.ct_eh_admin()
returns boolean language sql stable security definer set search_path = public, extensions as $$
  select exists (select 1 from public.ct_admins where email = lower(coalesce(auth.jwt() ->> 'email', '')));
$$;
revoke all on function public.ct_eh_admin() from public;
grant execute on function public.ct_eh_admin() to authenticated;

-- Dados do estúdio que aparecem para o cliente.
create table if not exists public.ct_config (
  id int primary key default 1 check (id = 1),
  nome_estudio text not null default 'Studio CT' check (char_length(nome_estudio) between 1 and 80),
  whatsapp text not null default '' check (whatsapp ~ '^[0-9]{0,15}$'),
  cor text not null default '#6C5CE7' check (cor ~ '^#[0-9A-F]{6}$'),
  atualizado_em timestamptz not null default now()
);
insert into public.ct_config (id) values (1) on conflict do nothing;

-- Pedidos.
create table if not exists public.ct_pedidos (
  id uuid primary key default gen_random_uuid(),
  codigo text not null unique default encode(extensions.gen_random_bytes(12), 'hex'),
  titulo text not null check (char_length(btrim(titulo)) between 1 and 120),
  tipo text not null default '' check (char_length(tipo) <= 60),
  cliente text not null default '' check (char_length(cliente) <= 120),
  telefone text not null default '' check (telefone ~ '^[0-9]{0,15}$'),
  quantidade integer not null check (quantidade between 1 and 1000000),
  feitos integer not null default 0,
  etapa text not null default 'fila' check (etapa in ('fila','producao','pausado','acabamento','pronto','entregue','cancelado')),
  inicio timestamptz not null default now(),
  prazo_horas numeric not null check (prazo_horas > 0 and prazo_horas <= 24 * 366),
  mensagem text not null default '' check (char_length(mensagem) <= 600),
  notas text not null default '' check (char_length(notas) <= 2000),
  valor numeric check (valor is null or (valor >= 0 and valor < 100000000)),
  pago numeric check (pago is null or (pago >= 0 and pago < 100000000)),
  criado_em timestamptz not null default now(),
  atualizado_em timestamptz not null default now(),
  constraint ct_feitos_validos check (feitos >= 0 and feitos <= quantidade)
);
create index if not exists ct_pedidos_atualizado on public.ct_pedidos (atualizado_em desc);

-- Versão 2: tipo de envio, WhatsApp de atendimento por pedido e chapas de impressão.
alter table public.ct_pedidos add column if not exists envio text not null default 'entrega';
alter table public.ct_pedidos add column if not exists whatsapp_atendimento text not null default '';
alter table public.ct_pedidos add column if not exists chapas integer;
alter table public.ct_pedidos add column if not exists por_chapa integer;
alter table public.ct_pedidos add column if not exists horas_chapa numeric;
alter table public.ct_pedidos drop constraint if exists ct_envio_valido;
alter table public.ct_pedidos add constraint ct_envio_valido check (envio in ('entrega','correios','retirada'));
alter table public.ct_pedidos drop constraint if exists ct_whats_atendimento;
alter table public.ct_pedidos add constraint ct_whats_atendimento check (whatsapp_atendimento ~ '^[0-9]{0,15}$');
alter table public.ct_pedidos drop constraint if exists ct_chapas_validas;
alter table public.ct_pedidos add constraint ct_chapas_validas check (
  (chapas is null or chapas between 1 and 10000) and (por_chapa is null or por_chapa between 1 and 1000000)
  and (horas_chapa is null or (horas_chapa > 0 and horas_chapa <= 24 * 60)));

-- Link curto: nome do cliente (ou do pedido) + parte aleatória que ninguém consegue adivinhar.
create or replace function public.ct_slug(t text) returns text language sql immutable as $$
  select left(btrim(regexp_replace(translate(lower(coalesce(t, '')),
    'áàãâäéèêëíìîïóòõôöúùûüçñ', 'aaaaaeeeeiiiiooooouuuucn'), '[^a-z0-9]+', '-', 'g'), '-'), 24);
$$;
create or replace function public.ct_novo_codigo()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare base text;
begin
  base := ct_slug(nullif(split_part(btrim(new.cliente), ' ', 1), ''));
  if base = '' then base := ct_slug(new.titulo); end if;
  if base = '' then base := 'pedido'; end if;
  new.codigo := base || '-' || encode(gen_random_bytes(6), 'hex');
  if new.feitos >= new.quantidade and new.etapa in ('fila', 'producao') then new.etapa := 'pronto'; end if;
  return new;
end;
$$;
drop trigger if exists ct_novo_codigo on public.ct_pedidos;
create trigger ct_novo_codigo before insert on public.ct_pedidos for each row execute function public.ct_novo_codigo();

-- Histórico que o cliente vê (gerado automaticamente a cada atualização).
create table if not exists public.ct_eventos (
  id bigint generated always as identity primary key,
  pedido_id uuid not null references public.ct_pedidos (id) on delete cascade,
  criado_em timestamptz not null default now(),
  tipo text not null check (tipo in ('criado','progresso','etapa','mensagem','prazo')),
  texto text not null default '',
  feitos integer
);
create index if not exists ct_eventos_pedido on public.ct_eventos (pedido_id, criado_em desc);

create or replace function public.ct_rotulo_etapa(e text) returns text language sql immutable as $$
  select case e when 'fila' then 'Na fila' when 'producao' then 'Em produção' when 'pausado' then 'Pausado'
    when 'acabamento' then 'Acabamento e embalagem' when 'pronto' then 'Pronto para entrega'
    when 'entregue' then 'Entregue' when 'cancelado' then 'Cancelado' else e end;
$$;

create or replace function public.ct_registrar()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
begin
  if tg_op = 'INSERT' then
    insert into ct_eventos (pedido_id, tipo, texto, feitos) values (new.id, 'criado', 'Pedido registrado', new.feitos);
    return new;
  end if;
  new.atualizado_em := now();
  new.criado_em := old.criado_em;
  new.codigo := old.codigo;
  -- Todas as peças prontas: o pedido passa sozinho para "Pronto".
  if new.feitos >= new.quantidade and new.etapa in ('fila', 'producao') then new.etapa := 'pronto'; end if;
  if new.feitos is distinct from old.feitos then
    insert into ct_eventos (pedido_id, tipo, texto, feitos) values (new.id, 'progresso',
      case when new.feitos > old.feitos then '+' || (new.feitos - old.feitos) || ' pronto(s)' else 'Contagem ajustada' end, new.feitos);
  end if;
  if new.etapa is distinct from old.etapa then
    insert into ct_eventos (pedido_id, tipo, texto, feitos) values (new.id, 'etapa', ct_rotulo_etapa(new.etapa), new.feitos);
  end if;
  if new.mensagem is distinct from old.mensagem and btrim(new.mensagem) <> '' then
    insert into ct_eventos (pedido_id, tipo, texto, feitos) values (new.id, 'mensagem', new.mensagem, new.feitos);
  end if;
  if new.prazo_horas is distinct from old.prazo_horas or new.inicio is distinct from old.inicio then
    insert into ct_eventos (pedido_id, tipo, texto, feitos) values (new.id, 'prazo', 'Previsão de entrega atualizada', new.feitos);
  end if;
  return new;
end;
$$;
drop trigger if exists ct_registrar_ins on public.ct_pedidos;
create trigger ct_registrar_ins after insert on public.ct_pedidos for each row execute function public.ct_registrar();
drop trigger if exists ct_registrar_upd on public.ct_pedidos;
create trigger ct_registrar_upd before update on public.ct_pedidos for each row execute function public.ct_registrar();

-- Regras: só administradores leem e alteram as tabelas.
alter table public.ct_pedidos enable row level security;
alter table public.ct_eventos enable row level security;
alter table public.ct_config enable row level security;
revoke all on public.ct_pedidos, public.ct_eventos, public.ct_config from anon;
revoke all on public.ct_pedidos, public.ct_eventos, public.ct_config from authenticated;
grant select, insert, update, delete on public.ct_pedidos to authenticated;
grant select on public.ct_eventos to authenticated;
grant select, update on public.ct_config to authenticated;

drop policy if exists "admin pedidos" on public.ct_pedidos;
create policy "admin pedidos" on public.ct_pedidos for all to authenticated using (public.ct_eh_admin()) with check (public.ct_eh_admin());
drop policy if exists "admin eventos" on public.ct_eventos;
create policy "admin eventos" on public.ct_eventos for select to authenticated using (public.ct_eh_admin());
drop policy if exists "admin config" on public.ct_config;
create policy "admin config" on public.ct_config for all to authenticated using (public.ct_eh_admin()) with check (public.ct_eh_admin());

-- =====================================================================
-- Versão 3: vários estúdios no mesmo sistema.
-- Cada estúdio tem nome, logo, cor, WhatsApp e prazos próprios, e só vê os próprios pedidos.
-- Quem está em ct_admins é dono da plataforma: cadastra estúdios e vê como cada um usa.
-- =====================================================================
create table if not exists public.ct_estudios (
  id uuid primary key default gen_random_uuid(),
  nome text not null check (char_length(btrim(nome)) between 1 and 80),
  whatsapp text not null default '' check (whatsapp ~ '^[0-9]{0,15}$'),
  cor text not null default '#B8862B' check (cor ~ '^#[0-9A-Fa-f]{6}$'),
  logo text not null default '' check (char_length(logo) <= 300000 and (logo = ''
    or logo ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$' or logo ~ '^assets/[a-z0-9._-]+$')),
  prazo_entrega text not null default 'de 2 a 5 dias corridos' check (char_length(btrim(prazo_entrega)) between 1 and 80),
  prazo_correios text not null default '2 a 3 dias úteis' check (char_length(btrim(prazo_correios)) between 1 and 80),
  ativo boolean not null default true,
  criado_em timestamptz not null default now()
);
-- Pagamento: chave Pix que o cliente vê e o sinal cobrado antes de começar (0 = não cobra sinal).
alter table public.ct_estudios add column if not exists pix_chave text not null default '';
alter table public.ct_estudios add column if not exists pix_nome text not null default '';
alter table public.ct_estudios add column if not exists sinal_pct integer not null default 0;
alter table public.ct_estudios drop constraint if exists ct_estudio_pagamento;
alter table public.ct_estudios add constraint ct_estudio_pagamento check (
  char_length(pix_chave) <= 140 and char_length(pix_nome) <= 80 and sinal_pct between 0 and 100);

-- Quem entra no painel de cada estúdio (pelo e-mail da conta).
create table if not exists public.ct_membros (
  email text primary key check (email = lower(email) and email ~ '^[^\s@]+@[^\s@]+\.[^\s@]+$'),
  estudio_id uuid not null references public.ct_estudios (id) on delete cascade,
  criado_em timestamptz not null default now()
);
create index if not exists ct_membros_estudio on public.ct_membros (estudio_id);
-- Sugestões enviadas pelo botão "Dar sugestão" do painel.
create table if not exists public.ct_sugestoes (
  id bigint generated always as identity primary key,
  estudio_id uuid references public.ct_estudios (id) on delete cascade,
  email text not null default '',
  texto text not null check (char_length(btrim(texto)) between 1 and 2000),
  criado_em timestamptz not null default now()
);
alter table public.ct_estudios enable row level security;
alter table public.ct_membros enable row level security;
alter table public.ct_sugestoes enable row level security;
revoke all on public.ct_estudios, public.ct_membros, public.ct_sugestoes from anon, authenticated;

create or replace function public.ct_email() returns text language sql stable as $$
  select lower(coalesce(auth.jwt() ->> 'email', ''));
$$;
-- Estúdio da conta conectada (só se estiver ativo).
create or replace function public.ct_meu_estudio()
returns uuid language sql stable security definer set search_path = public, extensions as $$
  select m.estudio_id from ct_membros m join ct_estudios e on e.id = m.estudio_id
  where m.email = ct_email() and e.ativo;
$$;
revoke all on function public.ct_meu_estudio() from public;
grant execute on function public.ct_meu_estudio() to authenticated;

alter table public.ct_pedidos add column if not exists estudio_id uuid references public.ct_estudios (id) on delete cascade;
create index if not exists ct_pedidos_estudio on public.ct_pedidos (estudio_id, criado_em desc);

-- Primeira vez: os pedidos que já existem passam a ser do StudioCT 3D.
do $$
declare novo uuid;
begin
  if not exists (select 1 from public.ct_estudios) then
    insert into public.ct_estudios (nome, whatsapp, cor, logo)
    values ('StudioCT 3D', coalesce((select whatsapp from public.ct_config where id = 1), ''), '#B8862B', 'assets/logo.webp')
    returning id into novo;
    update public.ct_pedidos set estudio_id = novo where estudio_id is null;
    insert into public.ct_membros (email, estudio_id) select email, novo from public.ct_admins on conflict do nothing;
  end if;
end $$;
alter table public.ct_pedidos alter column estudio_id set default public.ct_meu_estudio();
alter table public.ct_pedidos alter column estudio_id set not null;

-- Regras: cada conta só vê e altera os pedidos do próprio estúdio.
drop policy if exists "admin pedidos" on public.ct_pedidos;
drop policy if exists "estudio pedidos" on public.ct_pedidos;
create policy "estudio pedidos" on public.ct_pedidos for all to authenticated
  using (estudio_id = public.ct_meu_estudio()) with check (estudio_id = public.ct_meu_estudio());
drop policy if exists "admin eventos" on public.ct_eventos;
drop policy if exists "estudio eventos" on public.ct_eventos;
create policy "estudio eventos" on public.ct_eventos for select to authenticated
  using (exists (select 1 from public.ct_pedidos p where p.id = pedido_id));

-- Dados do estúdio no formato que as páginas usam.
create or replace function public.ct_estudio_json(e public.ct_estudios) returns json language sql stable as $$
  select json_build_object('id', e.id, 'nome', e.nome, 'whatsapp', e.whatsapp, 'cor', e.cor, 'logo', e.logo,
    'prazo_entrega', e.prazo_entrega, 'prazo_correios', e.prazo_correios, 'ativo', e.ativo,
    'pix_chave', e.pix_chave, 'pix_nome', e.pix_nome, 'sinal_pct', e.sinal_pct);
$$;

-- Quem sou eu: estúdio (mesmo pausado, para avisar) e se sou dono da plataforma.
create or replace function public.ct_minha_conta()
returns json language sql stable security definer set search_path = public, extensions as $$
  select json_build_object('email', ct_email(), 'dono_plataforma', ct_eh_admin(),
    'estudio', (select ct_estudio_json(e) from ct_membros m join ct_estudios e on e.id = m.estudio_id where m.email = ct_email()));
$$;
revoke all on function public.ct_minha_conta() from public;
grant execute on function public.ct_minha_conta() to authenticated;

-- Configurações do estúdio (qualquer pessoa do estúdio pode mudar). Logo null = mantém a atual.
drop function if exists public.ct_salvar_estudio(text, text, text, text, text, text);
create or replace function public.ct_salvar_estudio(p_nome text, p_whatsapp text, p_cor text, p_logo text,
  p_prazo_entrega text, p_prazo_correios text, p_pix_chave text default null, p_pix_nome text default null, p_sinal_pct integer default null)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare e ct_estudios; meu uuid := ct_meu_estudio();
begin
  if meu is null then raise exception 'Sem permissão' using errcode = '42501'; end if;
  update ct_estudios set nome = btrim(p_nome), whatsapp = coalesce(p_whatsapp, ''), cor = upper(p_cor),
    logo = coalesce(p_logo, logo), prazo_entrega = btrim(p_prazo_entrega), prazo_correios = btrim(p_prazo_correios),
    pix_chave = coalesce(btrim(p_pix_chave), pix_chave), pix_nome = coalesce(btrim(p_pix_nome), pix_nome),
    sinal_pct = coalesce(p_sinal_pct, sinal_pct)
  where id = meu returning * into e;
  return ct_estudio_json(e);
end;
$$;
revoke all on function public.ct_salvar_estudio(text, text, text, text, text, text, text, text, integer) from public;
grant execute on function public.ct_salvar_estudio(text, text, text, text, text, text, text, text, integer) to authenticated;

-- A própria pessoa cria o estúdio dela depois de confirmar o e-mail (uma conta = um estúdio).
create or replace function public.ct_criar_meu_estudio(p_nome text, p_whatsapp text default '')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare novo ct_estudios; em text := ct_email();
begin
  if em = '' then raise exception 'Sem permissão' using errcode = '42501'; end if;
  if exists (select 1 from ct_membros where email = em) then
    raise exception 'Esta conta já está em um estúdio' using errcode = '23505';
  end if;
  insert into ct_estudios (nome, whatsapp) values (btrim(p_nome), coalesce(p_whatsapp, '')) returning * into novo;
  insert into ct_membros (email, estudio_id) values (em, novo.id);
  return ct_estudio_json(novo);
end;
$$;
revoke all on function public.ct_criar_meu_estudio(text, text) from public;
grant execute on function public.ct_criar_meu_estudio(text, text) to authenticated;

create or replace function public.ct_enviar_sugestao(p_texto text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if ct_meu_estudio() is null and not ct_eh_admin() then raise exception 'Sem permissão' using errcode = '42501'; end if;
  insert into ct_sugestoes (estudio_id, email, texto) values (ct_meu_estudio(), ct_email(), btrim(p_texto));
end;
$$;
revoke all on function public.ct_enviar_sugestao(text) from public;
grant execute on function public.ct_enviar_sugestao(text) to authenticated;

-- ---------- Painel do dono da plataforma ----------
create or replace function public.ct_plat_checar() returns void language plpgsql stable security definer set search_path = public, extensions as $$
begin
  if not ct_eh_admin() then raise exception 'Sem permissão' using errcode = '42501'; end if;
end;
$$;
revoke all on function public.ct_plat_checar() from public;

create or replace function public.ct_plat_estudios()
returns json language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform ct_plat_checar();
  return coalesce((select json_agg(x order by x.criado_em) from (
    select e.id, e.nome, e.ativo, e.criado_em, (e.logo <> '') as tem_logo,
      coalesce((select json_agg(m.email order by m.criado_em) from ct_membros m where m.estudio_id = e.id), '[]') as pessoas,
      (select count(*) from ct_pedidos p where p.estudio_id = e.id) as pedidos,
      (select count(*) from ct_pedidos p where p.estudio_id = e.id and p.criado_em > now() - interval '30 days') as pedidos_30d,
      (select count(*) from ct_pedidos p where p.estudio_id = e.id and p.etapa not in ('pronto','entregue','cancelado')) as em_andamento,
      (select max(p.criado_em) from ct_pedidos p where p.estudio_id = e.id) as ultimo_pedido,
      (select max(p.atualizado_em) from ct_pedidos p where p.estudio_id = e.id) as ultima_atualizacao
    from ct_estudios e) x), '[]');
end;
$$;

create or replace function public.ct_plat_criar_estudio(p_nome text, p_email text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare novo uuid;
begin
  perform ct_plat_checar();
  if exists (select 1 from ct_membros where email = lower(btrim(p_email))) then
    raise exception 'Este e-mail já está em outro estúdio' using errcode = '23505';
  end if;
  insert into ct_estudios (nome) values (btrim(p_nome)) returning id into novo;
  insert into ct_membros (email, estudio_id) values (lower(btrim(p_email)), novo);
  return novo;
end;
$$;

create or replace function public.ct_plat_editar_estudio(p_id uuid, p_nome text, p_ativo boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform ct_plat_checar();
  update ct_estudios set nome = coalesce(nullif(btrim(p_nome), ''), nome), ativo = coalesce(p_ativo, ativo) where id = p_id;
end;
$$;

create or replace function public.ct_plat_add_pessoa(p_estudio uuid, p_email text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform ct_plat_checar();
  if exists (select 1 from ct_membros where email = lower(btrim(p_email))) then
    raise exception 'Este e-mail já está em um estúdio' using errcode = '23505';
  end if;
  insert into ct_membros (email, estudio_id) values (lower(btrim(p_email)), p_estudio);
end;
$$;

create or replace function public.ct_plat_del_pessoa(p_email text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform ct_plat_checar();
  delete from ct_membros where email = lower(btrim(p_email));
end;
$$;

create or replace function public.ct_plat_sugestoes()
returns json language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform ct_plat_checar();
  return coalesce((select json_agg(x order by x.criado_em desc) from (
    select s.id, s.texto, s.email, s.criado_em, e.nome as estudio
    from ct_sugestoes s left join ct_estudios e on e.id = s.estudio_id
    order by s.criado_em desc limit 200) x), '[]');
end;
$$;

do $$
declare f text;
begin
  foreach f in array array['ct_plat_estudios()', 'ct_plat_criar_estudio(text, text)', 'ct_plat_editar_estudio(uuid, text, boolean)',
    'ct_plat_add_pessoa(uuid, text)', 'ct_plat_del_pessoa(text)', 'ct_plat_sugestoes()'] loop
    execute format('revoke all on function public.%s from public', f);
    execute format('grant execute on function public.%s to authenticated', f);
  end loop;
end $$;

-- =====================================================================
-- Versão 4: número do pedido. Curto e em sequência dentro de cada estúdio (1001, 1002...).
-- O cliente informa o número no atendimento e o estúdio acha o pedido pela busca do painel.
-- =====================================================================
alter table public.ct_pedidos add column if not exists numero integer;
-- Pedidos que já existiam ganham número pela ordem de criação (sem mexer na data de atualização).
alter table public.ct_pedidos disable trigger user;
update public.ct_pedidos p set numero = n.num from (
  select q.id, coalesce((select max(x.numero) from public.ct_pedidos x where x.estudio_id = q.estudio_id), 1000)
    + row_number() over (partition by q.estudio_id order by q.criado_em, q.id) as num
  from public.ct_pedidos q where q.numero is null) n
where n.id = p.id;
alter table public.ct_pedidos enable trigger user;
alter table public.ct_pedidos alter column numero set not null;
create unique index if not exists ct_pedidos_numero on public.ct_pedidos (estudio_id, numero);

-- Pedido novo: código secreto do link, número em sequência do estúdio e etapa inicial.
create or replace function public.ct_novo_codigo()
returns trigger language plpgsql security definer set search_path = public, extensions as $$
declare base text;
begin
  base := ct_slug(nullif(split_part(btrim(new.cliente), ' ', 1), ''));
  if base = '' then base := ct_slug(new.titulo); end if;
  if base = '' then base := 'pedido'; end if;
  new.codigo := base || '-' || encode(gen_random_bytes(6), 'hex');
  -- Trava o estúdio enquanto numera, para dois pedidos salvos ao mesmo tempo não pegarem o mesmo número.
  perform 1 from ct_estudios where id = new.estudio_id for update;
  select coalesce(max(numero), 1000) + 1 into new.numero from ct_pedidos where estudio_id = new.estudio_id;
  if new.feitos >= new.quantidade and new.etapa in ('fila', 'producao') then new.etapa := 'pronto'; end if;
  return new;
end;
$$;
-- O pedido nunca muda de estúdio nem de número.
create or replace function public.ct_mesmo_estudio()
returns trigger language plpgsql as $$
begin
  new.estudio_id := old.estudio_id;
  new.numero := old.numero;
  return new;
end;
$$;
drop trigger if exists ct_mesmo_estudio on public.ct_pedidos;
create trigger ct_mesmo_estudio before update on public.ct_pedidos for each row execute function public.ct_mesmo_estudio();

-- =====================================================================
-- Versão 5: pagamento. O valor é opcional: sem valor, o cliente não vê nada de pagamento.
-- Com sinal, o pedido espera o sinal para começar; o restante (mais o frete) é pago quando fica pronto.
-- O dinheiro vai direto para a chave Pix do estúdio; aqui só fica registrado o que já foi recebido.
-- =====================================================================
alter table public.ct_pedidos add column if not exists frete numeric;
alter table public.ct_pedidos add column if not exists sinal_pct integer;
alter table public.ct_pedidos add column if not exists sinal_pago boolean not null default false;
alter table public.ct_pedidos add column if not exists quitado boolean not null default false;
alter table public.ct_pedidos drop constraint if exists ct_pagamento_valido;
alter table public.ct_pedidos add constraint ct_pagamento_valido check (
  (frete is null or (frete >= 0 and frete < 100000000)) and (sinal_pct is null or sinal_pct between 0 and 100));

-- O que o cliente vê, pelo código secreto do link: nada de telefone ou dados internos, e com a marca do estúdio.
-- A página manda o md5 da logo que já tem (p_logo_tenho) para não baixar a mesma logo a cada atualização.
drop function if exists public.ct_pedido_publico(text);
create or replace function public.ct_pedido_publico(p_codigo text, p_logo_tenho text default null)
returns json language sql stable security definer set search_path = public, extensions as $$
  select case when p.id is null then null else json_build_object(
    'numero', p.numero, 'titulo', p.titulo, 'tipo', p.tipo, 'cliente', split_part(btrim(p.cliente), ' ', 1),
    'quantidade', p.quantidade, 'feitos', p.feitos, 'etapa', p.etapa, 'envio', p.envio,
    'termino', p.inicio + make_interval(secs => p.prazo_horas * 3600),
    'mensagem', p.mensagem, 'atualizado_em', p.atualizado_em, 'agora', now(),
    'whatsapp', coalesce(nullif(p.whatsapp_atendimento, ''), nullif(e.whatsapp, ''), ''),
    'pagamento', case when p.valor is not null then json_build_object('valor', p.valor, 'frete', coalesce(p.frete, 0),
      'sinal_pct', coalesce(p.sinal_pct, 0), 'sinal_pago', p.sinal_pago, 'quitado', p.quitado,
      'pix_chave', e.pix_chave, 'pix_nome', e.pix_nome) end,
    'estudio', json_build_object('nome', e.nome, 'cor', e.cor,
      'logo', case when p_logo_tenho is not null and md5(e.logo) = p_logo_tenho then null else e.logo end,
      'logo_md5', md5(e.logo), 'prazo_entrega', e.prazo_entrega, 'prazo_correios', e.prazo_correios),
    -- No ritmo atual (só depois de 1 h de produção): horas para terminar o que falta.
    'ritmo_horas', case when p.etapa = 'producao' and p.feitos > 0 and p.feitos < p.quantidade and now() - p.inicio > interval '1 hour'
      then round(((p.quantidade - p.feitos) / (p.feitos / (extract(epoch from now() - p.inicio) / 3600)))::numeric, 2) end
  ) end
  from (select 1) x left join ct_pedidos p on p.codigo = p_codigo and char_length(p_codigo) >= 12
  left join ct_estudios e on e.id = p.estudio_id;
$$;
revoke all on function public.ct_pedido_publico(text, text) from public;
grant execute on function public.ct_pedido_publico(text, text) to anon, authenticated;

-- =====================================================================
-- Versão 6: cores (ou outras variações) e foto de referência do pedido.
-- Só o estúdio vê: a função do cliente (ct_pedido_publico) não devolve nenhum dos dois.
-- =====================================================================
alter table public.ct_pedidos add column if not exists cores jsonb;
alter table public.ct_pedidos add column if not exists foto_mini text;
alter table public.ct_pedidos drop constraint if exists ct_cores_validas;
alter table public.ct_pedidos add constraint ct_cores_validas check (
  cores is null or (jsonb_typeof(cores) = 'array' and jsonb_array_length(cores) between 1 and 40));
alter table public.ct_pedidos drop constraint if exists ct_foto_mini_valida;
alter table public.ct_pedidos add constraint ct_foto_mini_valida check (
  foto_mini is null or (char_length(foto_mini) <= 60000 and foto_mini ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$'));

-- Com cores, a quantidade e os prontos do pedido são sempre a soma das cores.
-- O nome do gatilho começa com "ct_a_" para rodar antes dos outros (que olham feitos e quantidade).
create or replace function public.ct_somar_cores()
returns trigger language plpgsql as $$
declare c jsonb; lista jsonb := '[]'::jsonb; nome text; q integer; f integer; tq integer := 0; tf integer := 0;
begin
  if new.cores is null or jsonb_typeof(new.cores) <> 'array' or jsonb_array_length(new.cores) = 0 then
    new.cores := null;
    return new;
  end if;
  for c in select value from jsonb_array_elements(new.cores) loop
    nome := left(btrim(coalesce(c ->> 'nome', '')), 40);
    q := floor(coalesce((c ->> 'qtd')::numeric, 0));
    f := floor(coalesce((c ->> 'feitos')::numeric, 0));
    if nome = '' or q < 1 or q > 1000000 then
      raise exception 'Cada cor precisa de um nome e de uma quantidade maior que zero' using errcode = '23514';
    end if;
    f := greatest(0, least(q, f));
    lista := lista || jsonb_build_array(jsonb_build_object('nome', nome, 'qtd', q, 'feitos', f));
    tq := tq + q; tf := tf + f;
  end loop;
  new.cores := lista;
  new.quantidade := tq;
  new.feitos := tf;
  return new;
end;
$$;
drop trigger if exists ct_a_cores on public.ct_pedidos;
create trigger ct_a_cores before insert or update on public.ct_pedidos for each row execute function public.ct_somar_cores();

-- Foto de referência: a original fica numa tabela à parte (só é baixada quando você abre a foto);
-- a miniatura fica no próprio pedido, para aparecer na lista.
create table if not exists public.ct_pedido_fotos (
  pedido_id uuid primary key references public.ct_pedidos (id) on delete cascade,
  foto text not null check (char_length(foto) <= 900000 and foto ~ '^data:image/(png|jpeg|webp);base64,[A-Za-z0-9+/=]+$'),
  atualizado_em timestamptz not null default now()
);
alter table public.ct_pedido_fotos enable row level security;
revoke all on public.ct_pedido_fotos from anon, authenticated;

-- Salva (ou, com p_foto vazio, apaga) a foto de um pedido do próprio estúdio.
create or replace function public.ct_salvar_foto(p_pedido uuid, p_foto text, p_mini text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from ct_pedidos where id = p_pedido and estudio_id = ct_meu_estudio()) then
    raise exception 'Sem permissão' using errcode = '42501';
  end if;
  if coalesce(p_foto, '') = '' then
    delete from ct_pedido_fotos where pedido_id = p_pedido;
    update ct_pedidos set foto_mini = null where id = p_pedido;
  else
    insert into ct_pedido_fotos (pedido_id, foto) values (p_pedido, p_foto)
      on conflict (pedido_id) do update set foto = excluded.foto, atualizado_em = now();
    update ct_pedidos set foto_mini = p_mini where id = p_pedido;
  end if;
end;
$$;
revoke all on function public.ct_salvar_foto(uuid, text, text) from public;
grant execute on function public.ct_salvar_foto(uuid, text, text) to authenticated;

-- Foto em tamanho original (só do próprio estúdio).
create or replace function public.ct_foto(p_pedido uuid)
returns text language sql stable security definer set search_path = public, extensions as $$
  select f.foto from ct_pedido_fotos f join ct_pedidos p on p.id = f.pedido_id
  where f.pedido_id = p_pedido and p.estudio_id = ct_meu_estudio();
$$;
revoke all on function public.ct_foto(uuid) from public;
grant execute on function public.ct_foto(uuid) to authenticated;

-- =====================================================================
-- Versão 7: assinatura dos estúdios (Cakto).
-- Cada estúdio tem "acesso até". Teste grátis, pagamento aprovado e renovação empurram essa data;
-- reembolso e chargeback cortam na hora. O estúdio do dono da plataforma é isento.
-- Os links dos clientes nunca são bloqueados: só o painel do estúdio.
-- =====================================================================
alter table public.ct_estudios add column if not exists isento boolean not null default false;
alter table public.ct_estudios add column if not exists acesso_ate timestamptz;
alter table public.ct_estudios add column if not exists assinatura_status text not null default 'nenhuma';
alter table public.ct_estudios add column if not exists assinatura_token text;
alter table public.ct_estudios add column if not exists cakto_assinatura text;
alter table public.ct_estudios add column if not exists assinatura_atualizada_em timestamptz;
alter table public.ct_estudios drop constraint if exists ct_assinatura_status_valido;
alter table public.ct_estudios add constraint ct_assinatura_status_valido check (
  assinatura_status in ('nenhuma', 'teste', 'ativa', 'atrasada', 'cancelada', 'reembolsada'));
update public.ct_estudios set assinatura_token = encode(extensions.gen_random_bytes(12), 'hex') where assinatura_token is null;
alter table public.ct_estudios alter column assinatura_token set default encode(extensions.gen_random_bytes(12), 'hex');
create unique index if not exists ct_estudios_token on public.ct_estudios (assinatura_token);
create index if not exists ct_estudios_cakto on public.ct_estudios (cakto_assinatura);
-- O estúdio de quem é dono da plataforma não paga.
update public.ct_estudios e set isento = true
where not e.isento and exists (select 1 from public.ct_membros m join public.ct_admins a on a.email = m.email where m.estudio_id = e.id);
-- Estúdios que já existiam antes da cobrança ganham 30 dias para se acostumar (uma vez só).
update public.ct_estudios set acesso_ate = now() + interval '30 days', assinatura_status = 'teste'
where not isento and acesso_ate is null and assinatura_status = 'nenhuma' and criado_em < '2026-11-24';

-- Configuração da cobrança (uma linha só). O segredo do webhook nunca sai do banco para o navegador.
create table if not exists public.ct_plataforma (
  id int primary key default 1 check (id = 1),
  dias_teste integer not null default 0 check (dias_teste between 0 and 90),
  dias_tolerancia integer not null default 3 check (dias_tolerancia between 0 and 30),
  cakto_checkout text not null default '' check (cakto_checkout = '' or cakto_checkout ~ '^https://[a-z0-9.-]+\.[a-z]{2,}(/[A-Za-z0-9._~/-]*)?$'),
  cakto_segredo text not null default '' check (char_length(cakto_segredo) <= 200),
  atualizado_em timestamptz not null default now()
);
insert into public.ct_plataforma (id) values (1) on conflict do nothing;
alter table public.ct_plataforma enable row level security;
revoke all on public.ct_plataforma from anon, authenticated;

-- Tudo o que a Cakto mandou fica registrado (sem o segredo). Eventos de quem ainda não tem estúdio
-- ficam pendentes e são aplicados quando a pessoa cria a conta com o mesmo e-mail.
create table if not exists public.ct_cakto_eventos (
  id bigint generated always as identity primary key,
  recebido_em timestamptz not null default now(),
  evento text not null,
  pedido_id text not null default '',
  email text not null default '',
  assinatura_id text not null default '',
  callback text not null default '',
  estudio_id uuid references public.ct_estudios (id) on delete set null,
  resultado text not null default '',
  dados jsonb not null default '{}'::jsonb
);
create index if not exists ct_cakto_eventos_email on public.ct_cakto_eventos (email) where estudio_id is null;
create unique index if not exists ct_cakto_eventos_unico on public.ct_cakto_eventos (evento, pedido_id) where pedido_id <> '';
alter table public.ct_cakto_eventos enable row level security;
revoke all on public.ct_cakto_eventos from anon, authenticated;

-- Tem acesso ao painel? (isento, ou "acesso até" no futuro). "ativo = false" é a pausa manual do dono.
create or replace function public.ct_tem_acesso(e public.ct_estudios) returns boolean language sql stable as $$
  select e.ativo and (e.isento or (e.acesso_ate is not null and e.acesso_ate > now()));
$$;

-- Estúdio da conta conectada, só se ativo e com acesso em dia. Sem isso, o banco não mostra nem grava pedidos.
create or replace function public.ct_meu_estudio()
returns uuid language sql stable security definer set search_path = public, extensions as $$
  select m.estudio_id from ct_membros m join ct_estudios e on e.id = m.estudio_id
  where m.email = ct_email() and ct_tem_acesso(e);
$$;

-- Situação da assinatura, para o painel do estúdio (inclui o link de pagamento só daquele estúdio).
create or replace function public.ct_assinatura_json(e public.ct_estudios) returns json language sql stable
set search_path = public, extensions as $$
  select json_build_object('isento', e.isento, 'status', e.assinatura_status, 'acesso_ate', e.acesso_ate,
    'tem_acesso', ct_tem_acesso(e), 'agora', now(),
    'checkout', case when c.cakto_checkout = '' then '' else c.cakto_checkout || '?callback=' || e.assinatura_token end)
  from ct_plataforma c where c.id = 1;
$$;

create or replace function public.ct_minha_conta()
returns json language sql stable security definer set search_path = public, extensions as $$
  select json_build_object('email', ct_email(), 'dono_plataforma', ct_eh_admin(),
    'estudio', (select ct_estudio_json(e) from ct_membros m join ct_estudios e on e.id = m.estudio_id where m.email = ct_email()),
    'assinatura', (select ct_assinatura_json(e) from ct_membros m join ct_estudios e on e.id = m.estudio_id where m.email = ct_email()));
$$;

-- Aplica um evento da Cakto num estúdio. Devolve o que fez (fica no registro).
create or replace function public.ct_srv_cakto_aplicar(p_estudio uuid, p_evento text, p_dados jsonb)
returns text language plpgsql security definer set search_path = public, extensions as $$
declare
  e ct_estudios; tol interval; prox timestamptz; dias int; sub_id text;
begin
  select * into e from ct_estudios where id = p_estudio for update;
  if not found then return 'estúdio não existe'; end if;
  select make_interval(days => dias_tolerancia) into tol from ct_plataforma where id = 1;
  sub_id := coalesce(p_dados #>> '{subscription,id}', '');
  prox := nullif(p_dados #>> '{subscription,next_payment_date}', '')::timestamptz;
  dias := coalesce(nullif(p_dados #>> '{subscription,recurrence_period}', '')::int, 30);

  if p_evento in ('purchase_approved', 'subscription_renewed', 'subscription_created', 'subscription_late_recovered', 'subscription_resumed') then
    if p_evento in ('subscription_created', 'subscription_resumed') and coalesce(p_dados ->> 'status', 'paid') <> 'paid' and prox is null then
      update ct_estudios set cakto_assinatura = coalesce(nullif(sub_id, ''), cakto_assinatura), assinatura_atualizada_em = now() where id = e.id;
      return 'assinatura registrada';
    end if;
    -- Pago: acesso até a próxima cobrança (ou um período a partir de agora), mais a tolerância.
    update ct_estudios set
      acesso_ate = greatest(coalesce(acesso_ate, now()), coalesce(prox, now() + make_interval(days => dias)) + tol),
      assinatura_status = 'ativa', cakto_assinatura = coalesce(nullif(sub_id, ''), cakto_assinatura), assinatura_atualizada_em = now()
    where id = e.id;
    return 'acesso liberado';
  elsif p_evento in ('subscription_late', 'subscription_renewal_refused') then
    update ct_estudios set assinatura_status = 'atrasada', assinatura_atualizada_em = now() where id = e.id;
    return 'marcado como atrasado (acesso segue até ' || to_char(e.acesso_ate at time zone 'America/Sao_Paulo', 'DD/MM HH24:MI') || ')';
  elsif p_evento in ('subscription_canceled', 'subscription_paused') then
    update ct_estudios set assinatura_status = 'cancelada', assinatura_atualizada_em = now() where id = e.id;
    return 'cancelado (acesso segue até o fim do período pago)';
  elsif p_evento in ('refund', 'chargeback') then
    update ct_estudios set assinatura_status = 'reembolsada', acesso_ate = least(coalesce(acesso_ate, now()), now()), assinatura_atualizada_em = now()
    where id = e.id and not isento;
    return 'acesso cortado (reembolso ou chargeback)';
  end if;
  return 'evento ignorado';
end;
$$;

-- Recebe um evento da Cakto (chamado só pela função do servidor, com a chave de serviço).
create or replace function public.ct_srv_cakto_receber(p_evento text, p_dados jsonb)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare
  v_email text := lower(btrim(coalesce(p_dados #>> '{customer,email}', '')));
  v_cb text := coalesce(p_dados ->> 'callback', '');
  v_sub text := coalesce(p_dados #>> '{subscription,id}', '');
  v_pedido text := coalesce(p_dados ->> 'id', '');
  v_estudio uuid; v_id bigint; v_res text;
begin
  if p_evento is null or p_evento = '' then return json_build_object('ok', false, 'motivo', 'sem evento'); end if;
  -- Mesmo evento do mesmo pedido já processado (a Cakto reenvia quando demora): ignora.
  if v_pedido <> '' and exists (select 1 from ct_cakto_eventos where evento = p_evento and pedido_id = v_pedido) then
    return json_build_object('ok', true, 'repetido', true);
  end if;
  -- Qual estúdio: pelo código do link de pagamento, pela assinatura já conhecida ou pelo e-mail da conta.
  if v_cb <> '' then select id into v_estudio from ct_estudios where assinatura_token = v_cb; end if;
  if v_estudio is null and v_sub <> '' then select id into v_estudio from ct_estudios where cakto_assinatura = v_sub limit 1; end if;
  if v_estudio is null and v_email <> '' then select estudio_id into v_estudio from ct_membros where email = v_email; end if;

  insert into ct_cakto_eventos (evento, pedido_id, email, assinatura_id, callback, estudio_id, dados)
  values (p_evento, v_pedido, v_email, v_sub, v_cb, v_estudio, p_dados - 'secret')
  on conflict do nothing returning id into v_id;
  if v_id is null then return json_build_object('ok', true, 'repetido', true); end if;

  if v_estudio is null then
    update ct_cakto_eventos set resultado = 'pendente: ninguém com este e-mail ainda' where id = v_id;
    return json_build_object('ok', true, 'pendente', true);
  end if;
  v_res := ct_srv_cakto_aplicar(v_estudio, p_evento, p_dados);
  update ct_cakto_eventos set resultado = v_res where id = v_id;
  return json_build_object('ok', true, 'resultado', v_res);
end;
$$;

-- Pagamentos feitos antes de a pessoa criar a conta: aplica quando o estúdio dela nasce (ou quando ela entra num).
create or replace function public.ct_srv_cakto_pendentes(p_estudio uuid, p_email text)
returns void language plpgsql security definer set search_path = public, extensions as $$
declare ev record;
begin
  for ev in select * from ct_cakto_eventos where estudio_id is null and email = lower(btrim(p_email)) order by recebido_em loop
    update ct_cakto_eventos set estudio_id = p_estudio, resultado = 'aplicado depois: ' || ct_srv_cakto_aplicar(p_estudio, ev.evento, ev.dados) where id = ev.id;
  end loop;
end;
$$;

-- Segredo do webhook, só para a função do servidor.
create or replace function public.ct_srv_cakto_segredo()
returns text language sql stable security definer set search_path = public, extensions as $$
  select cakto_segredo from ct_plataforma where id = 1;
$$;

-- Conta nova cria o próprio estúdio: começa no teste grátis (se houver) e recebe pagamentos feitos antes.
create or replace function public.ct_criar_meu_estudio(p_nome text, p_whatsapp text default '')
returns json language plpgsql security definer set search_path = public, extensions as $$
declare novo ct_estudios; em text := ct_email(); teste int;
begin
  if em = '' then raise exception 'Sem permissão' using errcode = '42501'; end if;
  if exists (select 1 from ct_membros where email = em) then
    raise exception 'Esta conta já está em um estúdio' using errcode = '23505';
  end if;
  select dias_teste into teste from ct_plataforma where id = 1;
  insert into ct_estudios (nome, whatsapp, isento, acesso_ate, assinatura_status)
  values (btrim(p_nome), coalesce(p_whatsapp, ''), ct_eh_admin(),
    case when coalesce(teste, 0) > 0 then now() + make_interval(days => teste) end,
    case when coalesce(teste, 0) > 0 then 'teste' else 'nenhuma' end)
  returning * into novo;
  insert into ct_membros (email, estudio_id) values (em, novo.id);
  perform ct_srv_cakto_pendentes(novo.id, em);
  select * into novo from ct_estudios where id = novo.id;
  return ct_estudio_json(novo);
end;
$$;

-- Painel do dono: lista com a situação da assinatura de cada estúdio.
create or replace function public.ct_plat_estudios()
returns json language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform ct_plat_checar();
  return coalesce((select json_agg(x order by x.criado_em) from (
    select e.id, e.nome, e.ativo, e.criado_em, (e.logo <> '') as tem_logo,
      e.isento, e.acesso_ate, e.assinatura_status, ct_tem_acesso(e) as tem_acesso, e.cakto_assinatura <> '' and e.cakto_assinatura is not null as na_cakto,
      coalesce((select json_agg(m.email order by m.criado_em) from ct_membros m where m.estudio_id = e.id), '[]') as pessoas,
      (select count(*) from ct_pedidos p where p.estudio_id = e.id) as pedidos,
      (select count(*) from ct_pedidos p where p.estudio_id = e.id and p.criado_em > now() - interval '30 days') as pedidos_30d,
      (select count(*) from ct_pedidos p where p.estudio_id = e.id and p.etapa not in ('pronto','entregue','cancelado')) as em_andamento,
      (select max(p.criado_em) from ct_pedidos p where p.estudio_id = e.id) as ultimo_pedido,
      (select max(p.atualizado_em) from ct_pedidos p where p.estudio_id = e.id) as ultima_atualizacao
    from ct_estudios e) x), '[]');
end;
$$;

-- Dono cria um estúdio para alguém: começa com os mesmos dias de teste de quem se cadastra sozinho.
create or replace function public.ct_plat_criar_estudio(p_nome text, p_email text)
returns uuid language plpgsql security definer set search_path = public, extensions as $$
declare novo uuid; teste int;
begin
  perform ct_plat_checar();
  if exists (select 1 from ct_membros where email = lower(btrim(p_email))) then
    raise exception 'Este e-mail já está em outro estúdio' using errcode = '23505';
  end if;
  select dias_teste into teste from ct_plataforma where id = 1;
  insert into ct_estudios (nome, acesso_ate, assinatura_status)
  values (btrim(p_nome), case when coalesce(teste, 0) > 0 then now() + make_interval(days => teste) end,
    case when coalesce(teste, 0) > 0 then 'teste' else 'nenhuma' end)
  returning id into novo;
  insert into ct_membros (email, estudio_id) values (lower(btrim(p_email)), novo);
  perform ct_srv_cakto_pendentes(novo, p_email);
  return novo;
end;
$$;

-- Dono: dar dias de acesso na mão (ex.: recebeu por Pix direto) ou isentar um estúdio.
create or replace function public.ct_plat_dar_acesso(p_id uuid, p_dias integer)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform ct_plat_checar();
  if p_dias is null or p_dias < 1 or p_dias > 400 then raise exception 'Dias inválidos' using errcode = '22023'; end if;
  update ct_estudios set acesso_ate = greatest(coalesce(acesso_ate, now()), now()) + make_interval(days => p_dias),
    assinatura_status = case when assinatura_status in ('nenhuma', 'teste', 'reembolsada') then 'ativa' else assinatura_status end,
    assinatura_atualizada_em = now() where id = p_id;
end;
$$;
create or replace function public.ct_plat_isentar(p_id uuid, p_isento boolean)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform ct_plat_checar();
  update ct_estudios set isento = coalesce(p_isento, false), assinatura_atualizada_em = now() where id = p_id;
end;
$$;

-- Dono: configuração da cobrança. O segredo só é gravado (nunca devolvido); vazio = mantém o atual.
create or replace function public.ct_plat_cobranca()
returns json language plpgsql stable security definer set search_path = public, extensions as $$
begin
  perform ct_plat_checar();
  return (select json_build_object('dias_teste', dias_teste, 'dias_tolerancia', dias_tolerancia, 'cakto_checkout', cakto_checkout,
    'tem_segredo', cakto_segredo <> '',
    'eventos', coalesce((select json_agg(x order by x.recebido_em desc) from (
      select ev.recebido_em, ev.evento, ev.email, ev.resultado, es.nome as estudio
      from ct_cakto_eventos ev left join ct_estudios es on es.id = ev.estudio_id order by ev.recebido_em desc limit 15) x), '[]'))
    from ct_plataforma where id = 1);
end;
$$;
create or replace function public.ct_plat_salvar_cobranca(p_dias_teste integer, p_dias_tolerancia integer, p_checkout text, p_segredo text)
returns void language plpgsql security definer set search_path = public, extensions as $$
begin
  perform ct_plat_checar();
  update ct_plataforma set dias_teste = coalesce(p_dias_teste, dias_teste), dias_tolerancia = coalesce(p_dias_tolerancia, dias_tolerancia),
    cakto_checkout = coalesce(regexp_replace(btrim(p_checkout), '[?#].*$', ''), cakto_checkout),
    cakto_segredo = coalesce(nullif(btrim(p_segredo), ''), cakto_segredo), atualizado_em = now()
  where id = 1;
end;
$$;

-- =====================================================================
-- ADMINISTRADORES: troque pelo seu e-mail (em minúsculas).
-- =====================================================================
insert into public.ct_admins (email) values ('psimoes2704@gmail.com') on conflict do nothing;
-- Instalação nova: o dono da plataforma também entra no primeiro estúdio.
insert into public.ct_membros (email, estudio_id)
select a.email, (select id from public.ct_estudios order by criado_em limit 1) from public.ct_admins a
where exists (select 1 from public.ct_estudios) and not exists (select 1 from public.ct_membros)
on conflict do nothing;
-- (o estúdio do dono da plataforma não paga, também numa instalação do zero)
update public.ct_estudios e set isento = true
where not e.isento and exists (select 1 from public.ct_membros m join public.ct_admins a on a.email = m.email where m.estudio_id = e.id);

-- Segurança extra: o Supabase libera toda função nova para visitantes sem login (anon).
-- Todas as funções já conferem quem está pedindo, mas aqui elas ficam fechadas para visitantes,
-- menos a da página do cliente (ct_pedido_publico).
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as assinatura from pg_proc p join pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname like 'ct\_%' and p.proname <> 'ct_pedido_publico' loop
    execute format('revoke execute on function %s from public, anon', f.assinatura);
    if f.assinatura::text like 'ct\_srv\_%' then
      execute format('revoke execute on function %s from authenticated', f.assinatura);
      execute format('grant execute on function %s to service_role', f.assinatura);
    else
      execute format('grant execute on function %s to authenticated', f.assinatura);
    end if;
  end loop;
end $$;
