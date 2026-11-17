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
    'prazo_entrega', e.prazo_entrega, 'prazo_correios', e.prazo_correios, 'ativo', e.ativo);
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
create or replace function public.ct_salvar_estudio(p_nome text, p_whatsapp text, p_cor text, p_logo text,
  p_prazo_entrega text, p_prazo_correios text)
returns json language plpgsql security definer set search_path = public, extensions as $$
declare e ct_estudios; meu uuid := ct_meu_estudio();
begin
  if meu is null then raise exception 'Sem permissão' using errcode = '42501'; end if;
  update ct_estudios set nome = btrim(p_nome), whatsapp = coalesce(p_whatsapp, ''), cor = upper(p_cor),
    logo = coalesce(p_logo, logo), prazo_entrega = btrim(p_prazo_entrega), prazo_correios = btrim(p_prazo_correios)
  where id = meu returning * into e;
  return ct_estudio_json(e);
end;
$$;
revoke all on function public.ct_salvar_estudio(text, text, text, text, text, text) from public;
grant execute on function public.ct_salvar_estudio(text, text, text, text, text, text) to authenticated;

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
-- ADMINISTRADORES: troque pelo seu e-mail (em minúsculas).
-- =====================================================================
insert into public.ct_admins (email) values ('psimoes2704@gmail.com') on conflict do nothing;
-- Instalação nova: o dono da plataforma também entra no primeiro estúdio.
insert into public.ct_membros (email, estudio_id)
select a.email, (select id from public.ct_estudios order by criado_em limit 1) from public.ct_admins a
where exists (select 1 from public.ct_estudios) and not exists (select 1 from public.ct_membros)
on conflict do nothing;
