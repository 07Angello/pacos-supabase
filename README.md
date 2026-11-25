# Paco's · Supabase (backend)

Backend compartido por la web de clientes (`../pacos-web`) y la app del personal (`../pacos-app`):
migraciones (esquema, RLS, RPCs, triggers, cron), Edge Functions, seed y scripts.

Esta carpeta es la "receta" del backend: con ella se recrea toda la lógica del negocio en
cualquier servidor de Supabase. **No** contiene datos (pedidos, menú, usuarios) ni las fotos del
bucket `products`; esos se respaldan aparte.

```bash
npm install
npm run db:start     # Supabase local en Docker
npm run db:reset     # recrea la BD local: migraciones + seed.sql
npm run db:push      # sube migraciones pendientes al proyecto enlazado
npm run db:stop
```

Detalle de cada migración, flujo de la CLI y configuración: [`supabase/README.md`](supabase/README.md).
