# cython: embedsignature=True

cimport cython

from brainpy._c.composition cimport (
    Element, Isotope, Composition,
    mass_charge_ratio, PROTON, element_max_neutron_shift,
    composition_get_element_count, element_monoisotopic_mass,
    composition_mass, get_isotope_by_neutron_shift, dict_to_composition,
    print_composition, free_composition, count_type,
    _ElementTable, element_hash_table_get, make_fixed_isotope_element,
    _parse_isotope_string, element_hash_table_put)

from brainpy._c.double_vector cimport(
    DoubleVector, make_double_vector, double_vector_append,
    free_double_vector, print_double_vector)

from libc.stdlib cimport malloc, free, realloc
from libc.string cimport strcmp
from libc.math cimport log, exp, sqrt
from libc cimport *

from brainpy._c.isotopic_constants cimport (
    IsotopicConstants, isotopic_constants_get, make_isotopic_constants,
    isotopic_constants_resize, free_isotopic_constants, isotopic_constants_add_element,
    isotopic_constants_get, isotopic_constants_update_coefficients,
    isotopic_constants_nth_element_power_sum, print_isotopic_constants,
    isotopic_constants_nth_modified_element_power_sum,
    newton)


from double_vector cimport (
    DoubleVector, free_double_vector, make_double_vector,
    double_vector_append, print_double_vector)

ctypedef DoubleVector dvec


cdef extern from * nogil:
    int printf (const char *template, ...)
    void qsort (void *base, unsigned short n, unsigned short w, int (*cmp_func)(void*, void*))


# -----------------------------------------------------------------------------
# ElementPolynomialMap Declaration and Methods

cdef struct ElementPolynomialMap:
    char** elements
    dvec** polynomials
    size_t used
    size_t size

cdef ElementPolynomialMap* make_element_polynomial_map(size_t sizehint) nogil:
    cdef ElementPolynomialMap* result
    result = <ElementPolynomialMap*>malloc(sizeof(ElementPolynomialMap))
    result.elements = <char**>malloc(sizeof(char*) * sizehint)
    result.polynomials = <dvec**>malloc(sizeof(dvec*) * sizehint)
    result.size = sizehint
    result.used = 0

    return result

cdef int element_polynomial_map_set(ElementPolynomialMap* ep_map, char* element, dvec* polynomial) nogil:
    cdef:
        size_t i
        int status
        bint done

    done = False
    i = 0
    while (i < ep_map.used):
        if strcmp(element, ep_map.elements[i]) == 0:
            done = True
            ep_map.polynomials[i] = polynomial
            return 0
        i += 1
    if not done:
        ep_map.used += 1
        if ep_map.used >= ep_map.size:
            printf("Overloaded ElementPolynomialMap\n %d, %d\n", i, ep_map.size)
            return -1
        ep_map.elements[i] = element
        ep_map.polynomials[i] = polynomial
        return 0
    return 1

cdef int element_polynomial_map_get(ElementPolynomialMap* ep_map, char* element, dvec** polynomial) nogil:
    cdef:
        size_t i
        int status
        bint done

    done = False
    i = 0
    while i < ep_map.used:
        if strcmp(ep_map.elements[i], element) == 0:
            polynomial[0] = ep_map.polynomials[i]
            return 0
        i += 1
    return 1

cdef void free_element_polynomial_map(ElementPolynomialMap* ep_map) nogil:
    cdef:
        size_t i
    i = 0
    while i < ep_map.used:
        free_double_vector(ep_map.polynomials[i])
        i += 1
    free(ep_map.elements)
    free(ep_map.polynomials)
    free(ep_map)


# -----------------------------------------------------------------------------
# Peak Methods

cdef void print_peak(Peak* peak) nogil:
    printf("Peak: %f, %f, %d\n", peak.mz, peak.intensity, peak.charge)


cdef Peak* make_peak(double mz, double intensity, int charge) nogil:
    cdef Peak* peak
    peak = <Peak*>malloc(sizeof(Peak))
    peak.mz = mz
    peak.intensity = intensity
    peak.charge = charge
    return peak

# -----------------------------------------------------------------------------
# PeakList Methods

cdef PeakList* make_peak_list() nogil:
    cdef PeakList* result

    result = <PeakList*>malloc(sizeof(PeakList))
    result.peaks = <Peak*>malloc(sizeof(Peak) * 10)
    result.size = 10
    result.used = 0

    return result


cdef void free_peak_list(PeakList* peaklist) nogil:
    free(peaklist.peaks)
    free(peaklist)

cdef int resize_peak_list(PeakList* peaklist) nogil:
    cdef:
        Peak* peaks
    peaks = <Peak*>realloc(peaklist.peaks, sizeof(Peak) * peaklist.size * 2)
    if peaks == NULL:
        printf("realloc peaklist returned NULL\n")
        return -1
    peaklist.peaks = peaks
    peaklist.size *= 2
    return 0


cdef void peak_list_append(PeakList* peaklist, Peak* peak) nogil:
    if peaklist.used == peaklist.size:
        resize_peak_list(peaklist)
    peaklist.peaks[peaklist.used] = peak[0]
    peaklist.used += 1

# -----------------------------------------------------------------------------
# Support Functions

cdef int max_variants(Composition* composition) nogil:
    cdef:
        size_t i
        int max_variants
        double count
        char* symbol
        Element* element

    max_variants = 0
    for i in range(composition.used):
        symbol = composition.elements[i]
        count = composition.counts[i]
        element_hash_table_get(_ElementTable, symbol, &element)
        max_variants += <int>(count) * element_max_neutron_shift(element)
    return max_variants


cdef void validate_composition(Composition* composition) nogil:
    cdef:
        size_t i
        char* element_symbol
        char* element_buffer
        int status, isotope_number
        Element* element

    for i in range(composition.used):
        element_symbol = composition.elements[i]
        status = element_hash_table_get(_ElementTable, element_symbol, &element)
        # printf("Element %s, Status %d\n", element_symbol, status)
        if status == -1:
            element_buffer = <char*>malloc(sizeof(char) * 10)
            # printf("Could not resolve element %s, attempting to generate fixed isotope\n", element_symbol)
            _parse_isotope_string(element_symbol, &isotope_number, element_buffer)
            # printf("Element: %s, Isotope: %d\n", element_buffer, isotope_number)
            if isotope_number != 0:
                element_hash_table_get(_ElementTable, element_buffer, &element)
                element = make_fixed_isotope_element(element, isotope_number)
                element_hash_table_put(_ElementTable, element)
                free(element_buffer)
            else:
                # printf("Could not resolve element %s\n", element_symbol)
                free(element_buffer)
                return

# -----------------------------------------------------------------------------
# IsotopicDistribution Methods

cdef void isotopic_distribution_update_isotopic_constants(IsotopicDistribution* distribution) nogil:
    cdef:
        size_t i
        Composition* composition
        IsotopicConstants* isotopes
        char* symbol

    composition = distribution.composition
    isotopes = distribution._isotopic_constants

    for i in range(composition.used):
        symbol = composition.elements[i]
        isotopic_constants_add_element(isotopes, symbol)
    isotopes.order = distribution.order
    isotopic_constants_update_coefficients(isotopes)


cdef void isotopic_distribution_update_order(IsotopicDistribution* distribution, int order) nogil:
    cdef:
        int possible_variants

    possible_variants = max_variants(distribution.composition)
    if order == -1:
        distribution.order = possible_variants
    else:
        distribution.order = min(order, possible_variants)

    isotopic_distribution_update_isotopic_constants(distribution)

cdef Peak* isotopic_distribution_make_monoisotopic_peak(IsotopicDistribution* distribution) nogil:
    cdef:
        Peak* peak
        size_t i
        Element* element
        int status
        double intensity

    peak = <Peak*>malloc(sizeof(Peak))
    peak.mz = composition_mass(distribution.composition)

    intensity = 0
    for i in range(distribution.composition.used):
        status = element_hash_table_get(_ElementTable, distribution.composition.elements[i], &element)
        intensity += log(get_isotope_by_neutron_shift(element.isotopes, 0).abundance)
    intensity = exp(intensity)
    peak.intensity = intensity
    peak.charge = 0
    return peak

cdef IsotopicDistribution* make_isotopic_distribution(Composition* composition, int order) nogil:
    cdef:
        IsotopicDistribution* result

    result = <IsotopicDistribution*>malloc(sizeof(IsotopicDistribution))
    result.composition = composition
    validate_composition(composition)
    result.order = 0
    result._isotopic_constants = make_isotopic_constants()
    isotopic_distribution_update_order(result, order)
    result.average_mass = 0
    result.monoisotopic_peak = isotopic_distribution_make_monoisotopic_peak(result)
    return result


cdef void free_isotopic_distribution(IsotopicDistribution* distribution)  nogil:
    free(distribution.monoisotopic_peak)
    free_isotopic_constants(distribution._isotopic_constants)
    free(distribution)


cdef dvec* id_phi_values(IsotopicDistribution* distribution) nogil:
    cdef:
        dvec* power_sum
        size_t i

    power_sum = make_double_vector()
    double_vector_append(power_sum, 0.)
    for i in range(1, distribution.order + 1):
        double_vector_append(power_sum, _id_phi_value(distribution, i))
    return power_sum


cdef double _id_phi_value(IsotopicDistribution* distribution, int order) nogil:
    cdef:
        double phi
        char* element
        double count
        size_t i

    phi = 0
    i = 0
    while i < distribution.composition.used:
        element = distribution.composition.elements[i]
        count = distribution.composition.counts[i]
        phi += isotopic_constants_nth_element_power_sum(
            distribution._isotopic_constants, element, order) * count
        i += 1
    return phi


cdef dvec* id_modified_phi_values(IsotopicDistribution* distribution, char* element) nogil:
    cdef:
        dvec* power_sum
        size_t i

    power_sum = make_double_vector()
    double_vector_append(power_sum, 0.)
    for i in range(1, distribution.order + 1):
        double_vector_append(power_sum,
                             _id_modified_phi_value(distribution, element, i))
    return power_sum


cdef double _id_modified_phi_value(IsotopicDistribution* distribution, char* symbol, int order) nogil:
    cdef:
        double phi
        char* element
        double count
        size_t i
        double coef

    phi = 0
    i = 0
    while i < distribution.composition.used:
        element = distribution.composition.elements[i]
        count = distribution.composition.counts[i]

        if strcmp(element, symbol) == 0:
            coef = count - 1
        else:
            coef = count

        phi += isotopic_constants_nth_element_power_sum(
            distribution._isotopic_constants, element, order) * coef
        i += 1

    phi += isotopic_constants_nth_modified_element_power_sum(
        distribution._isotopic_constants, symbol, order)

    return phi


cdef dvec* id_probability_vector(IsotopicDistribution* distribution) nogil:
    cdef:
        dvec* phi_values
        int max_variant_count
        dvec* probability_vector
        size_t i
        int sign

    probability_vector = make_double_vector()
    phi_values = id_phi_values(distribution)
    max_variant_count = max_variants(distribution.composition)

    newton(phi_values, probability_vector, max_variant_count)

    for i in range(0, probability_vector.used):
        sign = 1 if i % 2 == 0 else -1
        probability_vector.v[i] *= distribution.monoisotopic_peak.intensity * sign

    free_double_vector(phi_values)
    return probability_vector


@cython.cdivision
cdef dvec* id_center_mass_vector(IsotopicDistribution* distribution, dvec* probability_vector) nogil:
    cdef:
        dvec* mass_vector
        dvec* power_sum
        dvec* ele_sym_poly
        int max_variant_count, sign
        Element* element_struct
        char* element
        count_type _element_count
        double center, temp, polynomial_term
        double _monoisotopic_mass, base_intensity
        size_t i, j, k
        ElementPolynomialMap* ep_map

    mass_vector = make_double_vector()
    max_variant_count = max_variants(distribution.composition)
    base_intensity = distribution.monoisotopic_peak.intensity
    ep_map = make_element_polynomial_map(distribution.composition.size)

    j = 0
    while j < distribution.composition.used:
        element = distribution.composition.elements[j]
        power_sum = id_modified_phi_values(distribution, element)
        ele_sym_poly = make_double_vector()
        newton(power_sum, ele_sym_poly, max_variant_count)
        element_polynomial_map_set(ep_map, element, ele_sym_poly)
        free_double_vector(power_sum)
        j += 1
    i = 0
    for i in range(distribution.order + 1):
        sign = 1 if i % 2 == 0 else -1
        center = 0.0
        k = 0
        while k < ep_map.used:
            element = ep_map.elements[k]
            element_polynomial_map_get(ep_map, element, &ele_sym_poly)

            composition_get_element_count(distribution.composition, element, &_element_count)
            element_hash_table_get(_ElementTable, element, &element_struct)

            _monoisotopic_mass = element_monoisotopic_mass(element_struct)

            polynomial_term = ele_sym_poly.v[i]
            temp = _element_count
            temp *= sign * polynomial_term
            temp *= base_intensity * _monoisotopic_mass
            center += temp
            k += 1
        if probability_vector.v[i] == 0:
            double_vector_append(mass_vector, 0)
        else:
            double_vector_append(mass_vector, center / probability_vector.v[i])

    free_element_polynomial_map(ep_map)

    return mass_vector


@cython.cdivision
cdef PeakList* id_aggregated_isotopic_variants(IsotopicDistribution* distribution, int charge, double charge_carrier) nogil:
    cdef:
        dvec* probability_vector
        dvec* center_mass_vector
        PeakList* peak_set
        double average_mass, adjusted_mz
        double total
        size_t i
        Peak peak
        double center_mass_i, intensity_i

    probability_vector = id_probability_vector(distribution)
    center_mass_vector = id_center_mass_vector(distribution, probability_vector)

    peak_set = make_peak_list()

    average_mass = 0
    total = 0

    for i in range(probability_vector.used):
        total += probability_vector.v[i]

    for i in range(distribution.order + 1):
        center_mass_i = center_mass_vector.v[i]
        intensity_i = probability_vector.v[i]


        if charge != 0:
            adjusted_mz = mass_charge_ratio(center_mass_i, charge, charge_carrier)
        else:
            adjusted_mz = center_mass_i


        peak.mz = adjusted_mz
        peak.intensity = intensity_i / total
        peak.charge = charge

        if peak.intensity < 1e-10:
            continue

        peak_list_append(peak_set, &peak)

        average_mass += adjusted_mz * intensity_i

    average_mass /= total

    free_double_vector(probability_vector)
    free_double_vector(center_mass_vector)

    distribution.average_mass = average_mass

    sort_by_mz(peak_set)
    return peak_set

cdef void sort_by_mz(PeakList* peaklist) nogil:
    qsort(peaklist.peaks, peaklist.used, sizeof(Peak), compare_by_mz)

cdef int compare_by_mz(const void * a, const void * b) nogil:
    if (<Peak*>a).mz < (<Peak*>b).mz:
        return -1
    elif (<Peak*>a).mz == (<Peak*>b).mz:
        return 0
    elif (<Peak*>a).mz > (<Peak*>b).mz:
        return 1


cpdef bint check_composition_non_negative(dict composition):
    cdef:
        bint negative_element
        str k
        object v

    negative_element = False
    for k, v in composition.items():
        if v < 0:
            negative_element = True
            break
    return negative_element


def pyisotopic_variants(object composition not None, object npeaks=None, int charge=0,
                        double charge_carrier=PROTON):
    '''
    Compute a peak list representing the theoretical isotopic cluster for `composition`.

    Parameters
    ----------
    composition : Mapping
        Any Mapping type where keys are element symbols and values are integers
    n_peaks: int
        The number of peaks to include in the isotopic cluster, starting from the monoisotopic peak.
        If given a number below 1 or above the maximum number of isotopic variants, the maximum will
        be used. If `None`, a "reasonable" value is chosen by `int(sqrt(max_variants(composition)))`.
    charge: int
        The charge state of the isotopic cluster to produce. Defaults to 0, theoretical neutral mass.
    charge_carrier: double
        The mass of the molecule contributing the ion's charge

    Returns
    -------
    list of TheoreticalPeak
    '''
    return _isotopic_variants(composition, npeaks, charge, charge_carrier)


cpdef list _isotopic_variants(object composition, object npeaks=None, int charge=0, double charge_carrier=PROTON):
    '''
    Compute a peak list representing the theoretical isotopic cluster for `composition`.

    Parameters
    ----------
    composition : Mapping
        Any Mapping type where keys are element symbols and values are integers
    n_peaks: int
        The number of peaks to include in the isotopic cluster, starting from the monoisotopic peak.
        If given a number below 1 or above the maximum number of isotopic variants, the maximum will
        be used. If `None`, a "reasonable" value is chosen by `int(sqrt(max_variants(composition)))`.
    charge: int
        The charge state of the isotopic cluster to produce. Defaults to 0, theoretical neutral mass.
    charge_carrier: double
        The mass of the molecule contributing the ion's charge

    Returns
    -------
    list of TheoreticalPeak
    '''
    cdef:
        Composition* composition_struct
        list peaklist
        PeakList* peak_set
        IsotopicDistribution* dist
        int _npeaks, max_n_variants

    composition_struct = dict_to_composition(dict(composition))
    validate_composition(composition_struct)

    if npeaks is None:
        max_n_variants = max_variants(composition_struct)
        _npeaks = <int>sqrt(max_n_variants - 2)
        _npeaks = min(max(_npeaks, 3), 100)
    else:
        # The npeaks variable is left as a Python-level variable to
        # allow it to be any Python numeric type
        _npeaks = npeaks - 1

    dist = make_isotopic_distribution(composition_struct, _npeaks)
    peak_set = id_aggregated_isotopic_variants(dist, charge, charge_carrier)

    peaklist = peaklist_to_list(peak_set)

    free_peak_list(peak_set)
    free_isotopic_distribution(dist)
    free_composition(composition_struct)
    return peaklist


cdef PeakList* isotopic_variants(Composition* composition, int npeaks, int charge=0, double charge_carrier=PROTON) nogil:
    cdef:
        IsotopicDistribution* dist
        PeakList* peaklist
        int max_n_variants

    validate_composition(composition)

    if npeaks == 0:
        max_n_variants = max_variants(composition)
        npeaks = <int>sqrt(max_n_variants - 2)
        npeaks = min(max(npeaks, 3), 100)
    else:
        npeaks = npeaks - 1

    dist = make_isotopic_distribution(composition, npeaks)
    peaklist = id_aggregated_isotopic_variants(dist, charge, charge_carrier)
    free_isotopic_distribution(dist)

    return peaklist


cdef list peaklist_to_list(PeakList* peaklist):
    cdef:
        list pypeaklist
        size_t i
    pypeaklist = []
    for i in range(peaklist.used):
        pypeaklist.append(TheoreticalPeak._create(
            peaklist.peaks[i].mz, peaklist.peaks[i].intensity, peaklist.peaks[i].charge))
    return pypeaklist



cdef class TheoreticalPeak(object):
    def __init__(self, mz, intensity, charge):
        self.mz = mz
        self.intensity = intensity
        self.charge = charge

    def __repr__(self):
        return "Peak(mz=%f, intensity=%f, charge=%d)" % (self.mz, self.intensity, self.charge)

    def _eq(self, other):
        equal = (
            abs(self.mz - other.mz) < 1e-10,
            abs(self.intensity - other.intensity) < 1e-10,
            self.charge == other.charge
        )
        return all(equal)

    def __hash__(self):
        return hash((self.mz, self.intensity, self.charge))

    def __richcmp__(self, other, int code):
        if code == 2:
            return self._eq(other)
        elif code == 3:
            return not self._eq(other)

    def __reduce__(self):
        return TheoreticalPeak, (self.mz, self.intensity, self.charge)

    cpdef TheoreticalPeak clone(self):
        return TheoreticalPeak._create(self.mz, self.intensity, self.charge)

    @staticmethod
    cdef TheoreticalPeak _create(double mz, double intensity, int charge):
        cdef:
            TheoreticalPeak inst
        inst = TheoreticalPeak.__new__(TheoreticalPeak)
        inst.mz = mz
        inst.intensity = intensity
        inst.charge = charge
        return inst


def main():
    cdef:
        dict comp_dict
        Composition* composition
        IsotopicDistribution* distribution
        IsotopicDistribution* distribution2

    comp_dict = dict(H=2, O=1)
    print comp_dict
    composition = dict_to_composition(comp_dict)
    print_composition(composition)
    distribution = make_isotopic_distribution(composition, 4)
    print "Going to print constants"
    print_isotopic_constants(distribution._isotopic_constants)
    print "Done"

    print "Trying to free"
    free_isotopic_distribution(distribution)
    print "Free Done"

    distribution2 = make_isotopic_distribution(composition, 4)
    print "Seconc construction"
    print_isotopic_constants(distribution2._isotopic_constants)
    print "Second Free"
    free_isotopic_distribution(distribution2)
    print comp_dict
    free_composition(composition)
    print "Really done"
