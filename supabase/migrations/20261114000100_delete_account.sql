-- Eliminar la cuenta y todos sus datos, como exigen las tiendas de aplicaciones.
-- Solo la propia persona y con la palabra de confirmación. Todas las tablas cuelgan de auth.users con
-- ON DELETE CASCADE, así que borrar el usuario borra sus finanzas, lo aprendido, sus claves y sobres cifrados.
-- Las conexiones bancarias del servidor se revocan antes desde la app.
CREATE OR REPLACE FUNCTION public.finance_delete_account(confirmation text)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = ''
AS $$
DECLARE
    me uuid := auth.uid();
BEGIN
    IF me IS NULL THEN
        RAISE EXCEPTION 'unauthorized' USING ERRCODE = '42501';
    END IF;
    IF confirmation IS DISTINCT FROM 'ELIMINAR' THEN
        RAISE EXCEPTION 'confirmation_required' USING ERRCODE = '22023';
    END IF;
    DELETE FROM auth.users WHERE id = me;
END
$$;

REVOKE ALL ON FUNCTION public.finance_delete_account(text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.finance_delete_account(text) TO authenticated;
