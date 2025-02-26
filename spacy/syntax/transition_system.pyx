# cython: infer_types=True
# coding: utf-8
from __future__ import unicode_literals

from cpython.ref cimport Py_INCREF
from cymem.cymem cimport Pool
from thinc.typedefs cimport weight_t
from thinc.extra.search cimport Beam
from collections import OrderedDict, Counter
import srsly

from . cimport _beam_utils
from ..tokens.doc cimport Doc
from ..structs cimport TokenC
from .stateclass cimport StateClass
from ..typedefs cimport attr_t
from ..errors import Errors
from .. import util


cdef weight_t MIN_SCORE = -90000


class OracleError(Exception):
    pass


cdef void* _init_state(Pool mem, int length, void* tokens) except NULL:
    cdef StateC* st = new StateC(<const TokenC*>tokens, length)
    return <void*>st


cdef class TransitionSystem:
    def __init__(self, StringStore string_table, labels_by_action=None, min_freq=None):
        self.mem = Pool()
        self.strings = string_table
        self.n_moves = 0
        self._size = 100

        self.c = <Transition*>self.mem.alloc(self._size, sizeof(Transition))

        self.labels = {}
        if labels_by_action:
            self.initialize_actions(labels_by_action, min_freq=min_freq)
        self.root_label = self.strings.add('ROOT')
        self.init_beam_state = _init_state

    def __reduce__(self):
        return (self.__class__, (self.strings, self.labels), None, None)

    def init_batch(self, docs):
        cdef StateClass state
        states = []
        offset = 0
        for doc in docs:
            state = StateClass(doc, offset=offset)
            self.initialize_state(state.c)
            states.append(state)
            offset += len(doc)
        return states

    def init_beams(self, docs, beam_width, beam_density=0.):
        cdef Doc doc
        beams = []
        cdef int offset = 0
        for doc in docs:
            beam = Beam(self.n_moves, beam_width, min_density=beam_density)
            beam.initialize(self.init_beam_state, doc.length, doc.c)
            for i in range(beam.width):
                state = <StateC*>beam.at(i)
                state.offset = offset
            offset += len(doc)
            beam.check_done(_beam_utils.check_final_state, NULL)
            beams.append(beam)
        return beams

    def get_oracle_sequence(self, doc, GoldParse gold):
        cdef Pool mem = Pool()
        costs = <float*>mem.alloc(self.n_moves, sizeof(float))
        is_valid = <int*>mem.alloc(self.n_moves, sizeof(int))

        cdef StateClass state = StateClass(doc, offset=0)
        self.initialize_state(state.c)
        history = []
        while not state.is_final():
            self.set_costs(is_valid, costs, state, gold)
            for i in range(self.n_moves):
                if is_valid[i] and costs[i] <= 0:
                    action = self.c[i]
                    history.append(i)
                    action.do(state.c, action.label)
                    break
            else:
                raise ValueError(Errors.E024)
        return history

    def apply_transition(self, StateClass state, name):
        if not self.is_valid(state, name):
            raise ValueError(Errors.E170.format(name=name))
        action = self.lookup_transition(name)
        action.do(state.c, action.label)

    cdef int initialize_state(self, StateC* state) nogil:
        pass

    cdef int finalize_state(self, StateC* state) nogil:
        pass

    def finalize_doc(self, doc):
        pass

    def preprocess_gold(self, GoldParse gold):
        raise NotImplementedError

    def is_gold_parse(self, StateClass state, GoldParse gold):
        raise NotImplementedError

    cdef Transition lookup_transition(self, object name) except *:
        raise NotImplementedError

    cdef Transition init_transition(self, int clas, int move, attr_t label) except *:
        raise NotImplementedError

    def is_valid(self, StateClass stcls, move_name):
        action = self.lookup_transition(move_name)
        if action.move == 0:
            return False
        return action.is_valid(stcls.c, action.label)

    cdef int set_valid(self, int* is_valid, const StateC* st) nogil:
        cdef int i
        for i in range(self.n_moves):
            is_valid[i] = self.c[i].is_valid(st, self.c[i].label)

    cdef int set_costs(self, int* is_valid, weight_t* costs,
                       StateClass stcls, GoldParse gold) except -1:
        cdef int i
        self.set_valid(is_valid, stcls.c)
        cdef int n_gold = 0
        for i in range(self.n_moves):
            if is_valid[i]:
                costs[i] = self.c[i].get_cost(stcls, &gold.c, self.c[i].label)
                n_gold += costs[i] <= 0
            else:
                costs[i] = 9000
        if n_gold <= 0:
            raise ValueError(Errors.E024)

    def get_class_name(self, int clas):
        act = self.c[clas]
        return self.move_name(act.move, act.label)

    def initialize_actions(self, labels_by_action, min_freq=None):
        self.labels = {}
        self.n_moves = 0
        added_labels = []
        added_actions = {}
        for action, label_freqs in sorted(labels_by_action.items()):
            action = int(action)
            # Make sure we take a copy here, and that we get a Counter
            self.labels[action] = Counter()
            # Have to be careful here: Sorting must be stable, or our model
            # won't be read back in correctly.
            sorted_labels = [(f, L) for L, f in label_freqs.items()]
            sorted_labels.sort()
            sorted_labels.reverse()
            for freq, label_str in sorted_labels:
                if freq < 0:
                    added_labels.append((freq, label_str))
                    added_actions.setdefault(label_str, []).append(action)
                else:
                    self.add_action(int(action), label_str)
                    self.labels[action][label_str] = freq
        added_labels.sort(reverse=True)
        for freq, label_str in added_labels:
            for action in added_actions[label_str]:
                self.add_action(int(action), label_str)
                self.labels[action][label_str] = freq

    def add_action(self, int action, label_name):
        cdef attr_t label_id
        if not isinstance(label_name, int) and \
           not isinstance(label_name, long):
            label_id = self.strings.add(label_name)
        else:
            label_id = label_name
        # Check we're not creating a move we already have, so that this is
        # idempotent
        for trans in self.c[:self.n_moves]:
            if trans.move == action and trans.label == label_id:
                return 0
        if self.n_moves >= self._size:
            self._size *= 2
            self.c = <Transition*>self.mem.realloc(self.c, self._size * sizeof(self.c[0]))
        self.c[self.n_moves] = self.init_transition(self.n_moves, action, label_id)
        self.n_moves += 1
        # Add the new (action, label) pair, making up a frequency for it if
        # necessary. To preserve sort order, the frequency needs to be lower
        # than previous frequencies.
        if self.labels.get(action, []):
            new_freq = min(self.labels[action].values())
        else:
            self.labels[action] = Counter()
            new_freq = -1
        if new_freq > 0:
            new_freq = 0
        self.labels[action][label_name] = new_freq-1
        return 1

    def to_disk(self, path, **kwargs):
        with path.open('wb') as file_:
            file_.write(self.to_bytes(**kwargs))

    def from_disk(self, path, **kwargs):
        with path.open('rb') as file_:
            byte_data = file_.read()
        self.from_bytes(byte_data, **kwargs)
        return self

    def to_bytes(self, exclude=tuple(), **kwargs):
        transitions = []
        serializers = {
            'moves': lambda: srsly.json_dumps(self.labels),
            'strings': lambda: self.strings.to_bytes()
        }
        exclude = util.get_serialization_exclude(serializers, exclude, kwargs)
        return util.to_bytes(serializers, exclude)

    def from_bytes(self, bytes_data, exclude=tuple(), **kwargs):
        labels = {}
        deserializers = {
            'moves': lambda b: labels.update(srsly.json_loads(b)),
            'strings': lambda b: self.strings.from_bytes(b)
        }
        exclude = util.get_serialization_exclude(deserializers, exclude, kwargs)
        msg = util.from_bytes(bytes_data, deserializers, exclude)
        self.initialize_actions(labels)
        return self
