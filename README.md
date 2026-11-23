# Nexo | Acompanhamento de pedidos para estúdios de impressão 3D

Ferramenta para estúdios de impressão 3D: o cliente acompanha a produção do pedido por um link, sem login.
Ele vê quantas peças já estão prontas, quando termina, o tipo de envio e, se o estúdio usar, o valor a pagar com a chave Pix.

## Páginas
- **Página inicial:** `/` (`index.html`). Explica a ferramenta e tem uma demonstração que funciona.
- **Área de membros (painel do estúdio):** `/entrar` (ou `/administrador`, `admin.html`). A pessoa cria a própria conta, confirma o e-mail e monta o painel do estúdio dela.
- **Página do cliente:** `/apelido-do-estudio/1027-k7p2x` (`404.html`, que o GitHub Pages serve para endereços que não existem como arquivo).
  O apelido é escolhido em Configurações; `1027` é o número do pedido e `k7p2x` uma chave curta e secreta, para ninguém abrir
  o pedido de outra pessoa trocando o número. Os links antigos (`/p/nome-codigo` e `/?p=codigo`) continuam funcionando,
  e trocar o apelido não quebra os links já enviados (os apelidos antigos continuam do mesmo estúdio).

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

## Cadastro fechado
- Só cria o painel quem comprou na Cakto (com o mesmo e-mail) ou quem o dono liberou em **Estúdios › Liberar acesso**
  (teste por alguns dias ou grátis). Quem compra entra sozinho nessa lista, pelo webhook.
- A página inicial (marca Nexo) leva os botões "Assinar" direto ao checkout; a **Área de membros** é só para entrar
  ou criar a conta com o e-mail da compra.

## Marca
- Página inicial e área de membros usam a marca **Nexo** (`assets/nexo.css`, `assets/nexo.svg`, fontes Manrope e IBM Plex Mono
  em `assets/fontes`, com as licenças). A página do pedido não carrega nada da Nexo: lá aparecem só o nome, a logo e a cor do estúdio.

## Assinatura dos estúdios (Cakto)
- Cada estúdio tem "acesso até". Sem acesso, o painel mostra só a tela para assinar; os links dos clientes continuam abrindo.
- A Cakto avisa a função `supabase/functions/cakto-webhook` (publicada sem exigir login), que confere a assinatura HMAC
  e repassa para o banco (`ct_srv_cakto_receber`). Pagamento e renovação liberam; atraso avisa; reembolso e chargeback cortam.
- O link de pagamento leva `?callback=<código do estúdio>`, então a compra é ligada ao estúdio mesmo com outro e-mail.
- Tudo se configura no painel do dono, em **Estúdios › Cobrança (Cakto)**: link do checkout, código secreto do webhook,
  dias de teste grátis e de tolerância. Lá também aparecem os últimos avisos recebidos e os botões "+30 dias" e "Isentar".

## E-mails de confirmação
O cadastro usa o envio de e-mail do próprio Supabase, que no plano gratuito manda poucos e-mails por hora
e não permite personalizar o texto. Para abrir o cadastro ao público, configure um serviço de e-mail próprio
em **Authentication > Emails > SMTP Settings**.

## Domínio próprio (nexostud.com.br)
1. No GitHub: **Settings > Pages > Custom domain**, digite o domínio e salve.
2. No Registro.br, em **DNS**, crie 4 registros `A` apontando para o GitHub e um `CNAME` de `www` para `pedrooeditor.github.io`.
3. Volte em **Settings > Pages** e marque **Enforce HTTPS** quando liberar.
4. No Supabase, em **Authentication > URL Configuration**, adicione `https://nexostud.com.br/**` em **Redirect URLs** (para os links de confirmação e "esqueci a senha").
5. O endereço antigo (studioct3d.com.br) fica no repositório `nexo`, que só redireciona para o mesmo caminho em nexostud.com.br.
