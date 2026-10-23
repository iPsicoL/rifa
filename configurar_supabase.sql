-- Execute no SQL Editor após criar as tabelas e importar a LISTA(1).txt.
-- Não apaga os dados existentes.
BEGIN;

-- Somente dados necessários ao visitante (sem e-mail/telefone).
CREATE OR REPLACE VIEW public.rifa_publica AS
SELECT n.numero, c.nome AS comprador_nome
FROM public.numeros AS n
LEFT JOIN public.compradores AS c ON c.id = n.comprador_id;
GRANT SELECT ON public.rifa_publica TO anon, authenticated;

-- Login administrativo usa a função eh_admin criada na primeira etapa.
GRANT EXECUTE ON FUNCTION public.eh_admin() TO authenticated;

-- Permissões SQL + RLS já existentes limitam alterações a administradores.
GRANT SELECT, INSERT, UPDATE, DELETE ON public.compradores TO authenticated;
GRANT SELECT, UPDATE ON public.numeros TO authenticated;
GRANT USAGE, SELECT ON SEQUENCE public.compradores_id_seq TO authenticated;

-- Importação JSON atômica: substitui atribuições, mas mantém compradores existentes.
CREATE OR REPLACE FUNCTION public.importar_rifa_json(p_vendas jsonb)
RETURNS void LANGUAGE plpgsql SECURITY DEFINER SET search_path = '' AS $$
DECLARE item record; v_id bigint;
BEGIN
 IF NOT public.eh_admin() THEN RAISE EXCEPTION 'Acesso não autorizado'; END IF;
 IF jsonb_typeof(p_vendas) IS DISTINCT FROM 'object' THEN RAISE EXCEPTION 'JSON deve ser um objeto'; END IF;
 IF EXISTS (SELECT 1 FROM jsonb_each_text(p_vendas) WHERE key !~ '^[0-9]+$' OR key::integer NOT BETWEEN 1 AND 500 OR btrim(value) = '') THEN
   RAISE EXCEPTION 'Número ou comprador inválido';
 END IF;
 UPDATE public.numeros SET comprador_id = NULL WHERE comprador_id IS NOT NULL;
 FOR item IN SELECT key::integer AS numero, btrim(value) AS nome FROM jsonb_each_text(p_vendas) LOOP
   SELECT id INTO v_id FROM public.compradores WHERE nome = item.nome ORDER BY id LIMIT 1;
   IF v_id IS NULL THEN
     INSERT INTO public.compradores(nome) VALUES(item.nome) RETURNING id INTO v_id;
   END IF;
   UPDATE public.numeros SET comprador_id = v_id WHERE numero = item.numero;
 END LOOP;
END;
$$;
REVOKE ALL ON FUNCTION public.importar_rifa_json(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.importar_rifa_json(jsonb) TO authenticated;

-- Ativar notificações em tempo real.
DO $$ BEGIN
 IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='numeros') THEN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.numeros;
 END IF;
 IF NOT EXISTS (SELECT 1 FROM pg_publication_tables WHERE pubname='supabase_realtime' AND schemaname='public' AND tablename='compradores') THEN
  ALTER PUBLICATION supabase_realtime ADD TABLE public.compradores;
 END IF;
END $$;
COMMIT;

-- Verificação (esperado: 500 no total):
SELECT count(*) AS total, count(comprador_nome) AS vendidos
FROM public.rifa_publica;
