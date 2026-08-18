// pacs_core.cpp — OpenDicomViewer
//
// See pacs_core.hpp for the design rationale (C-GET over C-MOVE, curated storage SOP class
// presentation context list) and the IMPORTANT CAVEAT about verification level. This file's
// DCMTK API usage was syntax-checked with `clang++ -std=c++17 -fsyntax-only -Wall -Wextra`
// against the real DCMTK 3.6.8 headers cross-built in this sandbox (libs/dcmtk/include) and
// came back completely clean -- every class/method/enum name and signature below matches a
// real DCMTK declaration. That does not prove runtime correctness against a real PACS; see the
// caveat in the header.
#include "dcmtk/config/osconfig.h" /* must be included first, per DCMTK convention */
#include "pacs_core.hpp"

#include "dcmtk/dcmdata/dctk.h"
#include "dcmtk/dcmnet/scu.h"

#include <cstdlib>

namespace
{

/// DcmSCU subclass whose only job is to forward C-GET sub-operation progress (completed/
/// remaining/failed counts, already aggregated by DCMTK itself in RetrieveResponse) to a
/// std::function callback. Actual per-instance disk storage is left to DcmSCU's own default
/// handleSTORERequest() implementation (storageMode defaults to DCMSCU_STORAGE_DISK, and
/// setStorageDir() below points it at the caller's destination directory) -- there's no need to
/// override that too.
class OpenDicomViewerSCU : public DcmSCU
{
public:
    PACSRetrieveProgress progressCallback;

protected:
    virtual OFCondition handleCGETResponse(const T_ASC_PresentationContextID presID,
                                            RetrieveResponse* response,
                                            OFBool& continueCGETSession)
    {
        OFCondition cond = DcmSCU::handleCGETResponse(presID, response, continueCGETSession);
        if (response != NULL && progressCallback) {
            progressCallback(static_cast<int>(response->m_numberOfCompletedSubops),
                              static_cast<int>(response->m_numberOfRemainingSubops),
                              static_cast<int>(response->m_numberOfFailedSubops
                                                + response->m_numberOfWarningSubops));
        }
        return cond;
    }
};

/// Curated storage SOP classes -- see the "presentation contexts for storage SOP classes"
/// design note in pacs_core.hpp for why this isn't DCMTK's full dcmAllStorageSOPClassUIDs list.
const char* const kStorageSOPClasses[] = {
    UID_ComputedRadiographyImageStorage,
    UID_DigitalXRayImageStorageForPresentation,
    UID_CTImageStorage,
    UID_EnhancedCTImageStorage,
    UID_MRImageStorage,
    UID_EnhancedMRImageStorage,
    UID_UltrasoundImageStorage,
    UID_SecondaryCaptureImageStorage,
    UID_XRayAngiographicImageStorage,
    UID_NuclearMedicineImageStorage,
    UID_PositronEmissionTomographyImageStorage,
    UID_RTImageStorage,
    UID_RTDoseStorage,
    UID_RTStructureSetStorage,
    UID_RTPlanStorage
};
const size_t kNumStorageSOPClasses = sizeof(kStorageSOPClasses) / sizeof(kStorageSOPClasses[0]);

OFList<OFString> standardTransferSyntaxes()
{
    OFList<OFString> ts;
    ts.push_back(UID_LittleEndianExplicitTransferSyntax);
    ts.push_back(UID_LittleEndianImplicitTransferSyntax);
    // Baseline JPEG is included since dcmjpeg is already linked into this target for local-file
    // decode -- a PACS is free to send storage instances using it and this negotiates support
    // for that without requiring a transcode. Other compressed transfer syntaxes (JPEG-LS,
    // JPEG2000, RLE) are NOT proposed here -- only the ones this project's existing local-file
    // decode path already exercises are proposed for network transfer too, to avoid claiming
    // network support this hasn't had any chance to exercise even indirectly.
    ts.push_back(UID_JPEGProcess1TransferSyntax);
    return ts;
}

void addStorageSOPClassPresentationContexts(DcmSCU& scu, const T_ASC_SC_ROLE role)
{
    const OFList<OFString> ts = standardTransferSyntaxes();
    for (size_t i = 0; i < kNumStorageSOPClasses; ++i) {
        scu.addPresentationContext(kStorageSOPClasses[i], ts, role);
    }
}

/// Configures AE title/host/port/timeouts common to every operation below.
void configureSCU(DcmSCU& scu, const PACSNodeConfig& config)
{
    scu.setAETitle(config.callingAETitle.c_str());
    scu.setPeerHostName(config.host.c_str());
    scu.setPeerAETitle(config.calledAETitle.c_str());
    scu.setPeerPort(static_cast<Uint16>(config.port));
    scu.setDIMSEBlockingMode(DIMSE_BLOCKING);
    // Conservative but not unbounded timeouts -- a PACS on a slow WAN link (common for a
    // mobile/remote viewer, unlike a workstation on the hospital's own LAN) should get more
    // grace than DCMTK's short built-in defaults, but a hung/unreachable server still needs to
    // fail back to the UI in a reasonable time rather than blocking forever.
    scu.setACSETimeout(30);
    scu.setDIMSETimeout(60);
    scu.setConnectionTimeout(15);
}

std::string conditionText(const OFCondition& cond)
{
    return cond.text() != NULL ? std::string(cond.text()) : std::string("unknown DCMTK error");
}

} // namespace

PACSCore::PACSCore(const PACSNodeConfig& config)
    : m_config(config)
{
}

PACSCore::~PACSCore()
{
}

bool PACSCore::echo(std::string& errorOut)
{
    DcmSCU scu;
    configureSCU(scu, m_config);

    OFList<OFString> ts;
    ts.push_back(UID_LittleEndianExplicitTransferSyntax);
    ts.push_back(UID_LittleEndianImplicitTransferSyntax);
    scu.addPresentationContext(UID_VerificationSOPClass, ts);

    OFCondition cond = scu.initNetwork();
    if (cond.bad()) {
        errorOut = conditionText(cond);
        return false;
    }
    cond = scu.negotiateAssociation();
    if (cond.bad()) {
        errorOut = conditionText(cond);
        return false;
    }

    const T_ASC_PresentationContextID presID = scu.findAnyPresentationContextID(UID_VerificationSOPClass, "");
    if (presID == 0) {
        errorOut = "SCP did not accept the DICOM Verification (C-ECHO) presentation context";
        scu.releaseAssociation();
        return false;
    }

    cond = scu.sendECHORequest(presID);
    scu.releaseAssociation();
    if (cond.bad()) {
        errorOut = conditionText(cond);
        return false;
    }
    return true;
}

bool PACSCore::findStudies(const std::string& patientName,
                            const std::string& patientID,
                            const std::string& studyDate,
                            const std::string& accessionNumber,
                            std::vector<PACSStudyRecord>& results,
                            std::string& errorOut)
{
    results.clear();

    DcmSCU scu;
    configureSCU(scu, m_config);

    const OFList<OFString> ts = standardTransferSyntaxes();
    scu.addPresentationContext(UID_FINDStudyRootQueryRetrieveInformationModel, ts, ASC_SC_ROLE_SCU);

    OFCondition cond = scu.initNetwork();
    if (cond.bad()) {
        errorOut = conditionText(cond);
        return false;
    }
    cond = scu.negotiateAssociation();
    if (cond.bad()) {
        errorOut = conditionText(cond);
        return false;
    }

    const T_ASC_PresentationContextID presID =
        scu.findAnyPresentationContextID(UID_FINDStudyRootQueryRetrieveInformationModel, "");
    if (presID == 0) {
        errorOut = "SCP did not accept the Study Root C-FIND presentation context";
        scu.releaseAssociation();
        return false;
    }

    DcmDataset query;
    query.putAndInsertString(DCM_QueryRetrieveLevel, "STUDY");
    // Empty string = "don't filter" for every field except PatientName, whose DICOM universal
    // match wildcard is "*" (an empty PatientName value is technically also treated as
    // "match-all" by most SCPs, but "*" is the unambiguous, standard-sanctioned form).
    query.putAndInsertString(DCM_PatientName, patientName.empty() ? "*" : patientName.c_str());
    query.putAndInsertString(DCM_PatientID, patientID.c_str());
    query.putAndInsertString(DCM_StudyDate, studyDate.c_str());
    query.putAndInsertString(DCM_AccessionNumber, accessionNumber.c_str());
    // Return keys: attributes we want back in each result but aren't filtering on (empty value
    // in the query dataset means "return this attribute, don't constrain it").
    query.putAndInsertString(DCM_StudyInstanceUID, "");
    query.putAndInsertString(DCM_StudyDescription, "");
    query.putAndInsertString(DCM_ModalitiesInStudy, "");
    query.putAndInsertString(DCM_NumberOfStudyRelatedInstances, "");

    OFList<QRResponse*> responses;
    cond = scu.sendFINDRequest(presID, &query, &responses);
    if (cond.bad()) {
        errorOut = conditionText(cond);
        scu.releaseAssociation();
        return false;
    }

    for (OFListIterator(QRResponse*) it = responses.begin(); it != responses.end(); ++it) {
        QRResponse* resp = *it;
        if (resp == NULL || resp->m_dataset == NULL) {
            // The final C-FIND response (status Success) legitimately carries no dataset --
            // not an error, just nothing to record.
            continue;
        }
        PACSStudyRecord rec;
        OFString value;
        if (resp->m_dataset->findAndGetOFString(DCM_PatientName, value).good())
            rec.patientName = value.c_str();
        if (resp->m_dataset->findAndGetOFString(DCM_PatientID, value).good())
            rec.patientID = value.c_str();
        if (resp->m_dataset->findAndGetOFString(DCM_StudyInstanceUID, value).good())
            rec.studyInstanceUID = value.c_str();
        if (resp->m_dataset->findAndGetOFString(DCM_StudyDate, value).good())
            rec.studyDate = value.c_str();
        if (resp->m_dataset->findAndGetOFString(DCM_StudyDescription, value).good())
            rec.studyDescription = value.c_str();
        if (resp->m_dataset->findAndGetOFString(DCM_ModalitiesInStudy, value).good())
            rec.modalitiesInStudy = value.c_str();
        if (resp->m_dataset->findAndGetOFString(DCM_AccessionNumber, value).good())
            rec.accessionNumber = value.c_str();
        if (resp->m_dataset->findAndGetOFString(DCM_NumberOfStudyRelatedInstances, value).good()
            && !value.empty()) {
            rec.numberOfInstances = atoi(value.c_str());
        }
        // Skip a study with no StudyInstanceUID -- can't be retrieved later, and a well-behaved
        // SCP should never omit it, so treating it as unusable rather than displaying a
        // half-populated, non-retrievable row is the safer default.
        if (!rec.studyInstanceUID.empty()) {
            results.push_back(rec);
        }
    }

    for (OFListIterator(QRResponse*) it = responses.begin(); it != responses.end(); ++it) {
        delete *it;
    }

    scu.releaseAssociation();
    return true;
}

bool PACSCore::retrieveStudy(const std::string& studyInstanceUID,
                              const std::string& destinationDirectory,
                              int& completed,
                              int& failed,
                              const PACSRetrieveProgress& progress,
                              std::string& errorOut)
{
    completed = 0;
    failed = 0;

    OpenDicomViewerSCU scu;
    scu.progressCallback = progress;
    configureSCU(scu, m_config);
    scu.setStorageDir(destinationDirectory.c_str());

    const OFList<OFString> ts = standardTransferSyntaxes();
    scu.addPresentationContext(UID_GETStudyRootQueryRetrieveInformationModel, ts, ASC_SC_ROLE_SCU);
    // Storage presentation contexts negotiated with SCUSCP: this app is the SCU for the C-GET
    // request itself, but becomes the de-facto "SCP" receiving each C-STORE sub-operation the
    // PACS sends back on this same association -- see the C-GET design note in pacs_core.hpp.
    addStorageSOPClassPresentationContexts(scu, ASC_SC_ROLE_SCUSCP);

    OFCondition cond = scu.initNetwork();
    if (cond.bad()) {
        errorOut = conditionText(cond);
        return false;
    }
    cond = scu.negotiateAssociation();
    if (cond.bad()) {
        errorOut = conditionText(cond);
        return false;
    }

    const T_ASC_PresentationContextID presID =
        scu.findAnyPresentationContextID(UID_GETStudyRootQueryRetrieveInformationModel, "");
    if (presID == 0) {
        errorOut = "SCP did not accept the Study Root C-GET presentation context";
        scu.releaseAssociation();
        return false;
    }

    DcmDataset query;
    query.putAndInsertString(DCM_QueryRetrieveLevel, "STUDY");
    query.putAndInsertString(DCM_StudyInstanceUID, studyInstanceUID.c_str());

    OFList<RetrieveResponse*> responses;
    cond = scu.sendCGETRequest(presID, &query, &responses);
    if (cond.bad()) {
        errorOut = conditionText(cond);
        scu.releaseAssociation();
        return false;
    }

    for (OFListIterator(RetrieveResponse*) it = responses.begin(); it != responses.end(); ++it) {
        RetrieveResponse* r = *it;
        if (r == NULL) continue;
        // Each response's counts are cumulative-so-far per the DICOM standard, so the LAST
        // (final) response holds the authoritative end totals -- just keep overwriting as we
        // walk the list in order.
        completed = static_cast<int>(r->m_numberOfCompletedSubops);
        failed = static_cast<int>(r->m_numberOfFailedSubops + r->m_numberOfWarningSubops);
    }
    for (OFListIterator(RetrieveResponse*) it = responses.begin(); it != responses.end(); ++it) {
        delete *it;
    }

    scu.releaseAssociation();
    return true;
}

int PACSCore::storeFiles(const std::vector<std::string>& filePaths,
                          const PACSStoreProgress& progress,
                          std::string& errorOut)
{
    DcmSCU scu;
    configureSCU(scu, m_config);
    addStorageSOPClassPresentationContexts(scu, ASC_SC_ROLE_DEFAULT);

    OFCondition cond = scu.initNetwork();
    if (cond.bad()) {
        errorOut = conditionText(cond);
        return 0;
    }
    cond = scu.negotiateAssociation();
    if (cond.bad()) {
        errorOut = conditionText(cond);
        return 0;
    }

    int successCount = 0;
    const int total = static_cast<int>(filePaths.size());
    for (int i = 0; i < total; ++i) {
        const std::string& path = filePaths[static_cast<size_t>(i)];
        Uint16 rspStatusCode = 0;
        // presID=0: let DcmSCU pick the right presentation context itself based on the file's
        // own SOP Class UID / transfer syntax (see sendSTORERequest's doc comment in scu.h).
        OFCondition storeCond = scu.sendSTORERequest(0, OFFilename(path.c_str()), NULL, rspStatusCode);
        if (storeCond.good() && rspStatusCode == STATUS_Success) {
            ++successCount;
        }
        // A per-file failure (bad status, or storeCond.bad() from e.g. no matching presentation
        // context for that file's SOP class) is reported via progress and the loop continues --
        // only a hard association-level condition (checked implicitly by isConnected() below)
        // stops the whole batch.
        if (progress) {
            progress(successCount, total, path);
        }
        if (!scu.isConnected()) {
            errorOut = "Association was lost while sending files";
            break;
        }
    }

    scu.releaseAssociation();
    return successCount;
}
