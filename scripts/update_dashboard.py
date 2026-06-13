import urllib.request
import csv
import json
import re
import os
from collections import defaultdict
from datetime import datetime

# ID del archivo CSV en Google Drive
FILE_ID = '1kzILqi79vQDYDgd_l3Uzxax04nXmsQG9'
DOWNLOAD_URL = f'https://drive.google.com/uc?export=download&id={FILE_ID}'

print("Descargando CSV desde Google Drive...")
urllib.request.urlretrieve(DOWNLOAD_URL, 'datos_frescos.csv')

# Leer CSV
datos = []
with open('datos_frescos.csv', 'r', encoding='utf-8') as f:
    reader = csv.DictReader(f)
    for row in reader:
        row['cantidad'] = int(row['cantidad'])
        datos.append(row)

print(f"✓ {len(datos)} filas leídas")

# Estructurar datos
estructura = defaultdict(lambda: defaultdict(lambda: defaultdict(lambda: defaultdict(int))))
fechas_unicas = set()
estados_unicos = set()

for row in datos:
    fuente = row['fuente']
    canal = row['canal']
    estado = row['estado_especifico']
    fecha = row['fecha_creacion']
    cantidad = row['cantidad']
    estructura[fuente][canal][estado][fecha] += cantidad
    fechas_unicas.add(fecha)
    estados_unicos.add(estado)

fechas_ordenadas = sorted(list(fechas_unicas), reverse=True)
estados_ordenados = sorted(list(estados_unicos))
orden_estados = ['Calificado'] + sorted([e for e in estados_ordenados if e != 'Calificado'])

# Fuentes limpias
fuentes_limpias = {
    'WEB': sorted([c for c in estructura.get('WEB', {}).keys() if c.startswith('WEB')]),
    'Lead Forms': sorted([c for c in estructura.get('Lead Forms', {}).keys() if c.startswith('Lead Forms')]),
    'Estudio Inmueble': sorted([c for c in estructura.get('Estudio Inmueble', {}).keys() if c.startswith('Estudio Inmueble')])
}

data_output = {}
porcentajes_output = {}

for fuente, canales in fuentes_limpias.items():
    for canal in canales:
        key = f"{fuente}|{canal}"
        data_output[key] = {}
        porcentajes_output[key] = {}
        for estado in orden_estados:
            data_output[key][estado] = [estructura[fuente][canal][estado].get(f, 0) for f in fechas_ordenadas]
        for fecha in fechas_ordenadas:
            total = sum(estructura[fuente][canal][e].get(fecha, 0) for e in estados_unicos)
            calificados = estructura[fuente][canal]['Calificado'].get(fecha, 0)
            porcentajes_output[key][fecha] = {
                'total': total,
                'calificados': calificados,
                'no_calificados': total - calificados,
                'pct_calificados': round((calificados / total * 100) if total > 0 else 0, 2),
                'cvr': round((calificados / total) if total > 0 else 0, 4)
            }

# Ciclos
CICLOS = [
    (19, "2026-05-06", "2026-05-12"), (20, "2026-05-13", "2026-05-19"),
    (21, "2026-05-20", "2026-05-26"), (22, "2026-05-27", "2026-06-02"),
    (23, "2026-06-03", "2026-06-09"), (24, "2026-06-10", "2026-06-16"),
    (25, "2026-06-17", "2026-06-23"), (26, "2026-06-24", "2026-06-30"),
    (27, "2026-07-01", "2026-07-07"), (28, "2026-07-08", "2026-07-14"),
    (29, "2026-07-15", "2026-07-21"), (30, "2026-07-22", "2026-07-28"),
]

def get_ciclo(f):
    d = datetime.strptime(f, '%Y-%m-%d')
    for n, ini, fin in CICLOS:
        if datetime.strptime(ini, '%Y-%m-%d') <= d <= datetime.strptime(fin, '%Y-%m-%d'):
            return f"C{n} ({ini[5:]} → {fin[5:]})"
    return "Anterior"

def get_semana(f):
    d = datetime.strptime(f, '%Y-%m-%d')
    # Primer día (lunes) de esa semana ISO
    lunes = d - __import__('datetime').timedelta(days=d.weekday())
    return lunes.strftime('%d/%m')

def get_mes(f):
    meses = {'January':'Enero','February':'Febrero','March':'Marzo','April':'Abril',
             'May':'Mayo','June':'Junio','July':'Julio','August':'Agosto',
             'September':'Septiembre','October':'Octubre','November':'Noviembre','December':'Diciembre'}
    d = datetime.strptime(f, '%Y-%m-%d')
    return f"{meses[d.strftime('%B')]} {d.year}"

ciclo_g = defaultdict(list)
semana_g = defaultdict(list)
mes_g = defaultdict(list)
trimestre_g = defaultdict(list)
ano_g = defaultdict(list)

for f in fechas_ordenadas:
    ciclo_g[get_ciclo(f)].append(f)
    semana_g[get_semana(f)].append(f)
    mes_g[get_mes(f)].append(f)
    d = datetime.strptime(f, '%Y-%m-%d')
    trimestre_g[f"Q{(d.month-1)//3+1} {d.year}"].append(f)
    ano_g[f[:4]].append(f)

agrupaciones = {
    'por_dia': fechas_ordenadas,
    'por_ciclo': sorted(ciclo_g.items(), key=lambda x: x[1][0], reverse=True),
    'por_semana': sorted(semana_g.items(), key=lambda x: x[1][0], reverse=True),
    'por_mes': sorted(mes_g.items(), key=lambda x: x[1][0], reverse=True),
    'por_trimestre': sorted(trimestre_g.items(), key=lambda x: x[1][0], reverse=True),
    'por_ano': sorted(ano_g.items(), key=lambda x: x[1][0], reverse=True),
}

output = {
    'fechas': fechas_ordenadas,
    'fuentes': fuentes_limpias,
    'data': data_output,
    'porcentajes': porcentajes_output,
    'estados_orden': orden_estados,
    'actualizado': datetime.now().strftime('%Y-%m-%d %H:%M')
}

datos_json = json.dumps(output, ensure_ascii=False)
agrupaciones_json = json.dumps(agrupaciones, ensure_ascii=False)

# Leer y actualizar index.html
with open('index.html', 'r', encoding='utf-8') as f:
    html = f.read()

html = re.sub(r'const DATOS = \{.*?\};', f'const DATOS = {datos_json};', html, flags=re.DOTALL)
html = re.sub(r'const AGRUPACIONES = \{.*?\};', f'const AGRUPACIONES = {agrupaciones_json};', html, flags=re.DOTALL)

with open('index.html', 'w', encoding='utf-8') as f:
    f.write(html)

print(f"✓ Dashboard actualizado con {len(fechas_ordenadas)} fechas")
print(f"✓ Fuentes: {list(fuentes_limpias.keys())}")
