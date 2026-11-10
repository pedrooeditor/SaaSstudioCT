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
returns boolean language sql stable security definer set search_path = public as $$
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
  codigo text not null unique default encode(gen_random_bytes(12), 'hex'),
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
returns trigger language plpgsql security definer set search_path = public as $$
begin
  if tg_op = 'INSERT' then
    insert into ct_eventos (pedido_id, tipo, texto, feitos) values (new.id, 'criado', 'Pedido registrado', new.feitos);
    return new;
  end if;
  new.atualizado_em := now();
  new.criado_em := old.criado_em;
  new.codigo := old.codigo;
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

-- O que o cliente vê, pelo código secreto do link. Nada de telefone, valor ou notas internas.
create or replace function public.ct_pedido_publico(p_codigo text)
returns json language sql stable security definer set search_path = public as $$
  select case when p.id is null then null else json_build_object(
    'titulo', p.titulo, 'tipo', p.tipo, 'cliente', split_part(btrim(p.cliente), ' ', 1),
    'quantidade', p.quantidade, 'feitos', p.feitos, 'etapa', p.etapa,
    'inicio', p.inicio, 'previsao', p.inicio + make_interval(secs => p.prazo_horas * 3600),
    'prazo_horas', p.prazo_horas, 'mensagem', p.mensagem,
    'criado_em', p.criado_em, 'atualizado_em', p.atualizado_em, 'agora', now(),
    'estudio', (select json_build_object('nome', c.nome_estudio, 'whatsapp', c.whatsapp, 'cor', c.cor) from ct_config c where c.id = 1),
    'eventos', coalesce((select json_agg(json_build_object('em', e.criado_em, 'tipo', e.tipo, 'texto', e.texto, 'feitos', e.feitos) order by e.criado_em desc)
                         from (select * from ct_eventos where pedido_id = p.id order by criado_em desc limit 30) e), '[]'::json)
  ) end
  from (select 1) x left join ct_pedidos p on p.codigo = p_codigo and char_length(p_codigo) >= 20;
$$;
revoke all on function public.ct_pedido_publico(text) from public;
grant execute on function public.ct_pedido_publico(text) to anon, authenticated;

-- =====================================================================
-- ADMINISTRADORES: troque pelo seu e-mail (em minúsculas).
-- =====================================================================
insert into public.ct_admins (email) values ('psimoes2704@gmail.com') on conflict do nothing;
