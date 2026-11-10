# Studio CT | Acompanhamento de pedidos

Seus clientes acompanham a produção do pedido por um link, sem login:
quantas peças já estão prontas, quantas faltam, a previsão de entrega, a etapa atual e as atualizações.

- **Painel do estúdio:** `admin.html` (login de administrador)
- **Página do cliente:** `index.html?p=CODIGO` (o link é gerado no painel)

## Como funciona
- Os dados ficam no Supabase (`supabase/studioct.sql` cria as tabelas, as regras de acesso e a função pública).
- O cliente só consegue ver o pedido do próprio link, e nunca vê telefone, valor nem notas internas.
- O endereço do Supabase e a chave pública ficam em `config.js`. Nunca coloque ali a chave `service_role`/`secret`.

## Incluir outro administrador
No Supabase, em **SQL Editor**, rode:
```sql
insert into public.ct_admins (email) values ('email@exemplo.com') on conflict do nothing;
```
