# Setup — Google Calendar (cliente OAuth público)

O Client ID do Google fica em configuração local e não vive no repositório.
Como o Papagaio é um app desktop público, ele usa PKCE e não incorpora
`client_secret`: binários distribuídos não conseguem manter esse valor
confidencial.

## Setup (uma vez por máquina)

```bash
cp Config/Secrets.example.xcconfig Config/Secrets.xcconfig
```

Abra `Config/Secrets.xcconfig` e preencha com o identificador do
[Google Cloud Console](https://console.cloud.google.com)
(**APIs e Serviços → Credenciais → ID do cliente OAuth**, tipo
*Aplicativo para computador*):

```
GOOGLE_CLIENT_ID = 1234...apps.googleusercontent.com
```

Pronto. O arquivo é gitignored: `git pull`, merge e checkout nunca o
tocam. Sem ele o app compila normalmente — a seção Google Calendar só
aparece como "não configurada" nas Configurações.

## Como funciona

- `Config/Base.xcconfig` (versionado) faz `#include? "Secrets.xcconfig"`
  (opcional) e está ligado ao target como *base configuration*.
- A variável `GOOGLE_CLIENT_ID` vira um build setting.
- O `Config/Info.plist` versionado referencia `$(GOOGLE_CLIENT_ID)` nos
  valores; o Xcode expande no build (`infoPlistUtility -expandbuildsettings`).
  Keys nunca são expandidas, segredos nunca tocam o git.

## CI (Xcode Cloud)

Builds de nuvem não têm o arquivo local → integração Calendar fica
desabilitada no app de CI, sem erro. Para habilitar lá, defina a
variável de ambiente `GOOGLE_CLIENT_ID` no
workflow do Xcode Cloud e gere o xcconfig no `ci_post_clone.sh`.

## Segurança

O Client ID identifica o app, mas não é uma credencial confidencial. A
proteção do código de autorização vem de um verificador PKCE novo por fluxo e
da validação do parâmetro `state` no callback de loopback.

A conexão usa `prompt=consent`: a tela de consentimento do Google aparece e a
resposta traz o `refresh_token`. O navegador só é aberto quando a pessoa clica
em **Conectar**; renovações de fundo nunca abrem janelas.

## Se a troca do código falhar com `client_secret is missing`

Para clientes do tipo *Aplicativo para computador*, o endpoint de token do
Google pode exigir a "chave secreta do cliente" mesmo com PKCE. O app não a
envia, por decisão de projeto (há um teste que garante isso). Se a conexão
parar nesse erro, as saídas são: criar o cliente como tipo **iOS** (sem
segredo, com redirecionamento por esquema próprio — exige trocar o servidor de
loopback por um esquema de URL registrado) ou rever a decisão e embutir o
segredo do cliente desktop, que o Google não trata como confidencial. Este
ponto ainda não foi validado contra o servidor com uma conta nova.
