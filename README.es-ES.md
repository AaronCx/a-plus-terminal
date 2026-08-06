

# a+Terminal

Terminal SSH para iOS con enfoque en la privacidad para trabajar en tus propias máquinas desde tu iPhone — **agnóstico a agentes y multiplexores**. Ejecuta cualquier multiplexor de terminal (tmux, zellij, screen) y cualquier agente de programación por CLI con IA (Claude Code, Codex, aider, Gemini CLI, Hermes, …) mediante perfiles listos para usar que puedes extender por tu cuenta.

[![Download on the App Store](https://developer.apple.com/assets/elements/badges/download-on-the-app-store.svg)](https://apps.apple.com/app/id6779393452)

Gratis, con soporte voluntario. Ninguna función estará jamás de pago.

> No afiliado con Anthropic, OpenAI, Google o Nous Research; los nombres de los productos son marcas comerciales de sus respectivos propietarios.

## Capturas de pantalla

<p align="center">
  <img src=".github/assets/screenshot-agents.png" width="30%" alt="Sesión en vivo de un agente de codificación por CLI con IA sobre SSH y tmux, con la barra de teclas y el teclado visibles" />
  <img src=".github/assets/screenshot-sessions.png" width="30%" alt="Reanudar una sesión de multiplexor en ejecución al reconectar" />
  <img src=".github/assets/screenshot-privacy.png" width="30%" alt="La política de privacidad dentro de la app: no se rastrea nada, no se recopila nada" />
</p>

## Características

- Dos pestañas: **Terminal** (sesiones y servidores) y **Ajustes**.
- Desplazamiento de multiplexor de primera clase: los gestos de desplazamiento se convierten en eventos de rueda del mouse SGR, por lo que la salida de tu tmux/agente se desplaza como lo hace en el escritorio.
- Adjunta una imagen o archivo desde tu teléfono a través de la conexión SSH existente.
- Dictado por voz en el dispositivo directamente en la terminal (nunca se envía a un servidor).
- Seguimiento de sesiones en Actividades en vivo + Dynamic Island con toque para reanudar.
- **Monitor (VNC, beta):** una ventana hacia el compartir pantalla de tu computadora (autenticación ARD de macOS) — zoom con pellizco y desplazamiento. Extrae la pantalla a una ventana flotante de Imagen en imagen para mantenerla a la vista mientras usas otras apps. Solo para ver por defecto; el **modo Control** (habilitable) añade toque para hacer clic, arrastrar, clic derecho y una hoja de teclado que puede desbloquear un Mac bloqueado. Cuando tienes la misma máquina guardada como servidor SSH, a+Terminal transmite por SSH la posición real del puntero del mouse para que el cursor siga a tu mouse físico (el compartir pantalla de macOS no lo informa) — automáticamente, sin configuración.
- **Vista previa de localhost:** cuando un servidor de desarrollo en la máquina a la que estás conectado por SSH imprima `http://localhost:5173`, tócalo. a+Terminal reenvía ese puerto a través de la conexión SSH que ya tienes y renderiza la página en la app — con recarga en caliente y WebSockets incluidos, porque es un túnel de bytes sin procesar en lugar de un proxy de reescritura. Nada toca a un tercero y no se involucra ninguna cuenta; el oyente del túnel está vinculado solo al loopback del teléfono, por lo que nada más en tu Wi-Fi puede acceder a él. Es una vista previa, no un navegador: solo cargará direcciones de loopback y solo existirá mientras la app esté en primer plano — o, si la extraes a la ventana flotante, mientras esa ventana esté abierta. El panel de consola opcional refleja el `console.log` de la página para cuando necesites las herramientas de desarrollo y no haya ninguna; desactivado por defecto, ya que es la única parte que inyecta algo en tu página.
- Reconecta donde lo dejaste: las interrupciones en segundo plano permiten reanudar, con un selector de sesiones en vivo cuando hay varias sesiones de multiplexor en ejecución.

## Privacidad

**Cero recopilación de datos.** Sin analíticas, sin SDK de errores, sin cuentas, sin llamadas de red de terceros. El único tráfico de red son tus propias conexiones SSH (y monitor VNC opcional) a las máquinas que configuras.

Política completa: [política de privacidad](https://aaroncx.github.io/a-plus-terminal/privacy/).

## Requisitos

- iOS 26.0 o posterior, solo para iPhone.
- Una máquina a la que puedas acceder por SSH (autenticación por contraseña o clave; se admiten claves ed25519 y ECDSA).
- Para el modo Monitor: una máquina con compartir pantalla / VNC habilitado (Compartir pantalla de macOS funciona sin configuración adicional; acércate a ella a través de Tailscale o un túnel SSH).
- Para Vista previa: un servidor de desarrollo en ejecución en la máquina a la que ya estás conectado por SSH — sin configuración adicional, sin agente que instalar. El puerto reenviado está vinculado solo al loopback del teléfono, por lo que ningún otro dispositivo en tu red puede acceder a él.

## Soporte

- Preguntas o informes de errores: [GitHub Issues](https://github.com/AaronCx/a-plus-terminal/issues) — este es el canal de soporte para la publicación en la App Store.
- Guías: [configuración de tmux](https://aaroncx.github.io/a-plus-terminal/tmux-setup.html) y el [sitio del proyecto](https://aaroncx.github.io/a-plus-terminal/).

## Desarrollo

Requiere Xcode 26+ (SDK de iOS 26), [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
make generate   # regenerar aPlusTerminal.xcodeproj desde project.yml
make build      # compilar para el simulador de iOS
make test       # ejecutar pruebas unitarias
```

El `.xcodeproj` se genera y se ignora con git — edita `project.yml` en su lugar.

## Licencia

MIT — consulta [LICENSE](LICENSE).
