# (c) 2015, Filipe Niero Felisbino <filipenf@gmail.com>
#
# This file is part of Ansible
#
# Ansible is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Ansible is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Ansible.  If not, see <http://www.gnu.org/licenses/>.

from __future__ import (absolute_import, division, print_function)
__metaclass__ = type

from ansible.errors import AnsibleError
from ansible.plugins.lookup import LookupBase
from ansible.utils.listify import listify_lookup_plugin_terms

try:
    import jmespath
    HAS_LIB = True
except ImportError:
    HAS_LIB = False


class CustomFunctions(jmespath.functions.Functions):

    @jmespath.functions.signature({'types': ['object']})
    def _func_to_entries(self, o):
        return [dict(key=k, value=o[k]) for k in o.keys()]

    @jmespath.functions.signature({'types': ['array']})
    def _func_from_entries(self, l):
        ret = {}
        for item in l:
            if isinstance(item, dict):
                if 'key' in item.keys():
                    ret[item['key']] = item['value'] if 'value' in item.keys() else None
        return ret

    @jmespath.functions.signature({'types': ['array']})
    def _func_flatten_dict_entries(self, l):
        ret = {}
        for item in l:
            if isinstance(item, dict):
                for k, v in iter(item.items()):
                    ret[k] = v
        return ret


def json_query(data, expr):
    '''Query data using jmespath query language ( http://jmespath.org ). Example:
    - debug: msg="{{ instance | json_query(tagged_instances[*].block_device_mapping.*.volume_id') }}"
    '''
    if not HAS_LIB:
        raise AnsibleError('You need to install "jmespath" prior to running '
                           'json_query filter')

    jmespath.functions.REVERSE_TYPES_MAP['string'] = jmespath.functions.REVERSE_TYPES_MAP['string'] + ('AnsibleUnicode','AnsibleUnsafeText')
    options = jmespath.Options(custom_functions=CustomFunctions())

    return jmespath.search(expr, data, options=options)

class FilterModule(object):
    ''' Query filter '''

    def filters(self):
        return {
            'json_query': json_query
        }
