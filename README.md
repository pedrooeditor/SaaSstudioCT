# StudioCT 3D | Acompanhamento de pedidos

Ferramenta para estúdios de impressão 3D: o cliente acompanha a produção do pedido por um link, sem login.
Ele vê quantas peças já estão prontas, quando termina, o tipo de envio e, se o estúdio usar, o valor a pagar com a chave Pix.

## Páginas
- **Página inicial:** `/` (`index.html`). Explica a ferramenta e tem uma demonstração que funciona.
- **Área de membros (painel do estúdio):** `/administrador` (ou `admin.html`). A pessoa cria a própria conta, confirma o e-mail e monta o painel do estúdio dela.
- **Página do cliente:** `/p/nome-codigo` (`404.html`, que o GitHub Pages serve para esse endereço). O link é gerado no painel; `/?p=codigo` também funciona.

## Como funciona
- Os dados ficam no Supabase. `supabase/studioct.sql` cria as tabelas, as regras de acesso e as funções; pode ser rodado de novo sem perder dados.
- Cada estúdio só vê os próprios pedidos (regras do banco). O cliente só vê o pedido do próprio link, e nunca vê telefone ou dados internos.
- A tela do cliente fica em `assets/pedido.js` e `assets/pedido.css`; a página inicial usa a mesma tela na demonstração.
- Pagamento: o painel guarda o valor, o frete e o sinal; o cliente vê quanto pagar e a chave Pix do estúdio. O dinheiro vai direto para o estúdio, que marca no painel quando recebe.
- O endereço do Supabase e a chave pública ficam em `config.js`. Nunca coloque ali a chave `service_role`/`secret`.

## Dono da plataforma
Quem está na tabela `ct_admins` vê o menu **Estúdios**: lista todos os estúdios, o uso de cada um e as sugestões, e pode pausar um estúdio.
Para incluir outro dono, no Supabase, em **SQL Editor**:
```sql
insert into public.ct_admins (email) values ('email@exemplo.com') on conflict do nothing;
```

## E-mails de confirmação
O cadastro usa o envio de e-mail do próprio Supabase, que no plano gratuito manda poucos e-mails por hora
e não permite personalizar o texto. Para abrir o cadastro ao público, configure um serviço de e-mail próprio
em **Authentication > Emails > SMTP Settings**.

## Domínio próprio (studioct3d.com.br)
1. No GitHub: **Settings > Pages > Custom domain**, digite o domínio e salve.
2. No Registro.br, em **DNS**, crie 4 registros `A` apontando para o GitHub e um `CNAME` de `www` para `pedrooeditor.github.io`.
3. Volte em **Settings > Pages** e marque **Enforce HTTPS** quando liberar.
4. No Supabase, em **Authentication > URL Configuration**, adicione `https://studioct3d.com.br/**` em **Redirect URLs** (para os links de confirmação e "esqueci a senha").
