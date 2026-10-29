import Foundation
import SwiftData

@main
struct CloudPersistenceCheck {
    @MainActor static func main() throws {
        let schema = Schema([FinancialInstitution.self, FinancialAccount.self, PaymentCard.self, ReservedFund.self,
            FinanceCategory.self, FinancialTransaction.self, CategoryRule.self, MonthlyBudget.self, RecurringBudget.self,
            SavingsGoal.self, RecurringMovement.self, BalanceSnapshot.self, ImportBatch.self])
        func container() throws -> ModelContainer {
            try ModelContainer(for:schema,configurations:ModelConfiguration(isStoredInMemoryOnly:true))
        }
        let original=try container(), target=try container(), defaults=try container()
        let context=original.mainContext
        let institution=FinancialInstitution(name:"Entidad ficticia")
        let account=FinancialAccount(name:"Cuenta",type:.checking,openingBalanceMinor:10000,
            openingDate:Date(timeIntervalSince1970:0),institution:institution)
        let category=FinanceCategory(name:"Formación",kind:.expense)
        let fund=ReservedFund(name:"Estudios",amountMinor:1000,account:account)
        let batch=ImportBatch(fileName:"ficticio.csv",source:.csv)
        let recurring=RecurringMovement(name:"Cuota",type:.expense,amountMinor:500,descriptionText:"Cuota",
            frequency:.monthly,nextDueDate:.now,sourceAccount:account,category:category)
        context.insert(institution); context.insert(account); context.insert(category); context.insert(fund); context.insert(batch); context.insert(recurring)
        context.insert(PaymentCard(name:"Tarjeta",type:.debit,lastFour:"1234",linkedAccount:account))
        context.insert(CategoryRule(phrase:"Escuela",transactionType:.expense,category:category))
        context.insert(MonthlyBudget(monthStart:Date.now.startOfMonth(),limitMinor:10000,category:category))
        context.insert(RecurringBudget(startMonth:Date.now.startOfMonth(),baseLimitMinor:10000,remainderChoice:.carryForward,category:category))
        context.insert(SavingsGoal(name:"Objetivo",targetAmountMinor:20000,linkedAccount:account))
        context.insert(BalanceSnapshot(date:.now,balanceMinor:9500,account:account))
        context.insert(FinancialTransaction(date:.now,type:.expense,amountMinor:500,descriptionText:"Matrícula",
            importBatchID:batch.id,reservedFundID:fund.id,reservedAmountMinor:500,sourceAccount:account,category:category))
        try context.save()
        let document=try CloudBackupAdapter.document(in:context)
        try CloudBackupAdapter.apply(CloudBackupAdapter.backup(from:document),in:target.mainContext)
        let captured=try CloudBackupAdapter.document(in:target.mainContext)
        let roundTrip=try CloudDocument.same(document,captured)
        precondition(roundTrip,"Every entity must survive the cloud/local adapter")
        let accountBefore=try target.mainContext.fetch(FetchDescriptor<FinancialAccount>())[0]
        var changed=document.object
        var accountFields=changed["accounts"]!.array[0].object
        accountFields["name"] = .string("Cuenta actualizada desde otro dispositivo")
        changed["accounts"] = .array([.object(accountFields)])
        try CloudBackupAdapter.apply(CloudBackupAdapter.backup(from:.object(changed)),in:target.mainContext)
        let accountAfter=try target.mainContext.fetch(FetchDescriptor<FinancialAccount>())[0]
        precondition(accountBefore === accountAfter,"A remote edit must preserve an open model identity")
        precondition(accountAfter.name == "Cuenta actualizada desde otro dispositivo")
        let transaction=try target.mainContext.fetch(FetchDescriptor<FinancialTransaction>())[0]
        precondition(transaction.sourceAccount === accountBefore && transaction.reservedFundID == fund.id)
        let counts=try BackupService.capture(in:target.mainContext).totalRecords
        try CloudBackupAdapter.apply(CloudBackupAdapter.backup(from:.object(changed)),in:target.mainContext)
        precondition(tryCount(target.mainContext)==counts,"Repeated pulls must not duplicate records")
        var invalid=changed
        var payment=invalid["transactions"]!.array[0].object
        payment["reservedAmountMinor"] = .integer(50000)
        invalid["transactions"] = .array([.object(payment)])
        do {
            try CloudBackupAdapter.apply(CloudBackupAdapter.backup(from:.object(invalid)),in:target.mainContext)
            preconditionFailure("Invalid allocation was accepted")
        } catch is BackupError { }
        precondition(tryCount(target.mainContext)==counts,"A failed pull must leave the local graph intact")
        changed["transactions"] = .array([]); changed["reservedFunds"] = .array([])
        try CloudBackupAdapter.apply(CloudBackupAdapter.backup(from:.object(changed)),in:target.mainContext)
        let remaining=try target.mainContext.fetch(FetchDescriptor<FinancialTransaction>())
        let remainingFunds=try target.mainContext.fetch(FetchDescriptor<ReservedFund>())
        precondition(remaining.isEmpty && remainingFunds.isEmpty)
        try CategoryDefaultsService.restoreMissing(in:defaults.mainContext,stableIDs:true)
        let another=try container()
        try CategoryDefaultsService.restoreMissing(in:another.mainContext,stableIDs:true)
        let ids=Set(try defaults.mainContext.fetch(FetchDescriptor<FinanceCategory>()).map(\.id))
        let otherIDs=Set(try another.mainContext.fetch(FetchDescriptor<FinanceCategory>()).map(\.id))
        precondition(ids == otherIDs,"Two new devices must install the same default category identities")
        print("Cloud persistence passed: all entities, model identity, relations, reserved payments, repeated pulls, invalid data rollback, deletions and stable default categories.")
    }
    @MainActor private static func tryCount(_ context:ModelContext)->Int {
        (try? BackupService.capture(in:context).totalRecords) ?? -1
    }
}
