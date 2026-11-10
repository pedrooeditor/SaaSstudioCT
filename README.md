# StudioCT 3D | Acompanhamento de pedidos

Seus clientes acompanham a produção do pedido por um link, sem login:
quantas peças já estão prontas, quantas faltam, a previsão de entrega, a etapa atual e as atualizações.

- **Painel do estúdio:** `/administrador` (ou `admin.html`), com login
- **Página do cliente:** `/p/nome-codigo` (o link é gerado no painel; `?p=codigo` também funciona)

## Como funciona
- Os dados ficam no Supabase (`supabase/studioct.sql` cria as tabelas, as regras de acesso e a função pública).
- O cliente só consegue ver o pedido do próprio link, e nunca vê telefone, valor nem notas internas.
- O endereço do Supabase e a chave pública ficam em `config.js`. Nunca coloque ali a chave `service_role`/`secret`.

## Incluir outro administrador
No Supabase, em **SQL Editor**, rode:
```sql
insert into public.ct_admins (email) values ('email@exemplo.com') on conflict do nothing;
```

## Domínio próprio (ex.: studioct3d.com.br)
1. Compre o domínio (Registro.br, para `.com.br`).
2. No GitHub: **Settings > Pages > Custom domain**, digite `studioct3d.com.br` e salve.
3. No Registro.br, em **DNS**, crie os registros que o GitHub mostrar (4 registros `A` apontando para o GitHub e um `CNAME` de `www` para `pedrooeditor.github.io`).
4. Volte em **Settings > Pages** e marque **Enforce HTTPS** quando liberar.
5. No Supabase, em **Authentication > URL Configuration**, adicione `https://studioct3d.com.br/**` em **Redirect URLs** (para os links de confirmação e "esqueci a senha").

Depois disso o painel fica em `studioct3d.com.br/administrador` e os links novos saem como
`studioct3d.com.br/p/rafael-a41fae502151`, sem precisar mudar nada no código.
