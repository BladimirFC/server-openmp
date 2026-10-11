(() => {
  'use strict';
  const byId = id => document.getElementById(id);
  const password = byId('password');
  const status = byId('status');
  const parameters = new URLSearchParams(location.search);
  const session = Number(parameters.get('session'));
  const epoch = Number(parameters.get('epoch'));
  const bridge = window.cef;
  let ready = false;
  let busy = true;
  let register = false;
  let retry;
  const emit = (event, ...args) => bridge.emit(event, session, epoch, ...args);
  const setBusy = value => {
    busy = value;
    for (const id of ['password', 'submit', 'toggle-password', 'classic']) byId(id).disabled = !ready || busy;
    byId('cancel').disabled = !ready;
    byId('submit-label').textContent = busy ? 'Procesando…' : register ? 'Crear mi cuenta' : 'Entrar al servidor';
  };
  const clearPassword = () => {
    password.value = '';
    password.type = 'password';
    byId('toggle-password').textContent = 'Mostrar';
    byId('toggle-password').setAttribute('aria-label', 'Mostrar contraseña');
    byId('toggle-password').setAttribute('aria-pressed', 'false');
  };
  if (!bridge || typeof bridge.on !== 'function' || typeof bridge.emit !== 'function'
      || !Number.isInteger(session) || session <= 0 || !Number.isInteger(epoch) || epoch <= 0) {
    byId('heading').textContent = 'Acceso al servidor';
    byId('intro').textContent = 'Esta pantalla se abre desde el servidor dentro de GTA.';
    status.textContent = 'Vista previa: el acceso está deshabilitado fuera del juego.';
    return;
  }
  bridge.on('auth:state', (name, isRegister, isBusy, message) => {
    if (typeof name !== 'string' || typeof isRegister !== 'boolean' || typeof isBusy !== 'boolean' || typeof message !== 'string') return;
    const first = !ready;
    ready = true;
    clearInterval(retry);
    // El servidor determina la cuenta y la operacion; no existe un selector de nombre.
    if (first || !isBusy) register = isRegister;
    byId('account-name').textContent = name;
    byId('heading').textContent = register ? 'Crea tu cuenta.' : 'Bienvenido de vuelta.';
    byId('intro').textContent = register ? 'Un nuevo nombre, una nueva historia. Elige tu contraseña para empezar.' : 'Tu siguiente capítulo te espera. Ingresa tu contraseña para continuar.';
    byId('password-help').textContent = register ? 'Entre 8 y 72 caracteres ASCII. Para otros caracteres, usa Acceso clásico.' : 'Para contraseñas con caracteres fuera de ASCII, usa Acceso clásico.';
    status.textContent = message;
    setBusy(isBusy);
    if (first || !isBusy) password.focus();
  });
  byId('auth-form').addEventListener('submit', event => {
    event.preventDefault();
    if (!ready || busy) return;
    const value = password.value;
    if (value.length > 72 || (register && value.length < 8)) { status.textContent = register ? 'La contraseña debe tener entre 8 y 72 caracteres.' : 'La contraseña no puede superar 72 caracteres.'; return; }
    if (/[^\x20-\x7e]/.test(value)) { status.textContent = 'Para esta contraseña usa Acceso clásico.'; return; }
    clearPassword();
    status.textContent = '';
    setBusy(true);
    emit('auth:submit', value);
  });
  byId('toggle-password').addEventListener('click', () => {
    const visible = password.type === 'password';
    password.type = visible ? 'text' : 'password';
    byId('toggle-password').textContent = visible ? 'Ocultar' : 'Mostrar';
    byId('toggle-password').setAttribute('aria-label', visible ? 'Ocultar contraseña' : 'Mostrar contraseña');
    byId('toggle-password').setAttribute('aria-pressed', String(visible));
  });
  byId('cancel').addEventListener('click', () => { clearPassword(); emit('auth:cancel'); });
  byId('classic').addEventListener('click', () => { if (!ready || busy) return; clearPassword(); emit('auth:fallback'); });
  window.addEventListener('pagehide', clearPassword);
  retry = setInterval(() => { if (!ready) emit('auth:ready'); }, 500);
  emit('auth:ready');
})();
